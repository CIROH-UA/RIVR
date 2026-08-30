// functions/src/store-firestore.ts
//
// ADR 0011 Phase 4: the Firestore side of the store — the only file here that
// touches the database or the network. Everything it depends on is pure and
// tested separately; this is the seam where those decisions become writes.
//
// THE TRANSACTION IS NOT OPTIONAL. Guard 6 says overlapping runs cannot write
// backwards and must be tested "by interleaving two runs". A read-then-write
// pair cannot satisfy that: two invocations can both read the same old
// document and both write, and the loser silently wins. Runs DO overlap here —
// the hourly schedule plus write-through on favourite plus a retry pass can all
// be in flight at once — so the supersession check has to happen INSIDE a
// transaction, re-reading under lock.

import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";

import {StoreDocument, shouldWrite} from "./store-document.js";
import {FatalRunError, FetchedProduct, StoreRunDeps} from "./store-run.js";
import {StoredWindowSample, WindowExtension} from "./store-window.js";
import {ForecastProductId, ForecastSourceId, STORE_COLLECTION}
  from "./store-keys.js";
import {FavouritingUser} from "./store-work-list.js";
import {assertPayloadFits, trimPayload} from "./store-payload.js";
import {ProbeRuns, oldestLiveRun} from "./store-trigger.js";

if (!admin.apps.length) {
  admin.initializeApp();
}
const db = admin.firestore();

/** Counters for guard 11, incremented by the adapter as it works. */
export interface FirestoreUsage {
  reads: number;
  writes: number;
  deletes: number;
}

export function newUsage(): FirestoreUsage {
  return {reads: 0, writes: 0, deletes: 0};
}

/**
 * Every user document, not just the notification audience.
 *
 * The store serves the app's read path, so a favourite belonging to a user who
 * has notifications switched off must still be kept fresh. Filtering here the
 * way the alert path does would under-cover the store silently.
 *
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<FavouritingUser[]>} All users.
 */
export async function readAllUsers(
  usage: FirestoreUsage
): Promise<FavouritingUser[]> {
  const snap = await db.collection("users").get();
  usage.reads += snap.size;
  return snap.docs.map((d) => {
    const data = d.data();
    return {
      userId: d.id,
      favoriteReachIds: data.favoriteReachIds,
      favoriteSources: data.favoriteSources ?? {},
    };
  });
}

/**
 * The most recent probe sample.
 *
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<ProbeRuns | null>} Latest sample, or null when none exists.
 */
export async function readLatestProbe(
  usage: FirestoreUsage
): Promise<ProbeRuns | null> {
  const snap = await db.collection("publish_cadence_log")
    .orderBy("sampledAt", "desc").limit(1).get();
  usage.reads += snap.size;
  if (snap.empty) return null;

  const data = snap.docs[0].data();
  const sampledAt = data.sampledAt?.toDate?.();
  if (!(sampledAt instanceof Date)) return null;
  return {
    referenceTimes: (data.referenceTimes ?? {}) as Record<string,
      string | null>,
    sampledAt,
  };
}


/**
 * The oldest stored run for a product, counting ONLY documents this run could
 * actually update.
 *
 * The obvious implementation takes the oldest run across EVERY document of a
 * product,
 * which is right for a lagging favourite and wrong for an orphan. A reach that
 * nobody favourites any more leaves its documents behind for the GC's seven-day
 * grace; they are not in the work list, so no run will ever rewrite them, and
 * their run identity is frozen. Sampling them means the oldest stored run is
 * permanently in the past, every product reads as "upstream advanced" every
 * hour, and the store performs a full fan-out that writes nothing.
 *
 * Measured 2026-08-29: four documents from reach 9962444, last written
 * 2026-08-24, made every hourly run plan 116 fetches and write 0 — the exact
 * behaviour Phase 4 guard 1 ("no new run means zero fetches") exists to
 * prevent, running unnoticed since whenever that reach was unfavourited.
 *
 * Restricting to the work list keeps the ascending sample doing its real job:
 * a followed reach that is behind still holds the sample back and is
 * revisited. Costs one read per document rather than one per product, which is
 * the price of the decision being about documents that can actually move.
 *
 * @param {readonly ForecastProductId[]} products - Products to sample.
 * @param {ReadonlySet<string>} liveDocumentIds - Document IDs the work list
 *   covers; anything else is an orphan awaiting GC.
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<object>} Oldest live run per product, or null.
 */
export async function sampleLiveStoredRuns(
  products: readonly ForecastProductId[],
  liveDocumentIds: ReadonlySet<string>,
  usage: FirestoreUsage
): Promise<Partial<Record<ForecastProductId, string | null>>> {
  const out: Partial<Record<ForecastProductId, string | null>> = {};
  for (const product of products) {
    const snap = await db.collection(STORE_COLLECTION)
      .where("product", "==", product)
      .select("runId")
      .get();
    usage.reads += snap.size;

    // The selection itself is pure and tested in store-trigger.test.ts; this
    // function only supplies the documents.
    out[product] = oldestLiveRun(
      snap.docs.map((d) => ({
        documentId: d.id,
        runId: (d.data().runId as string | undefined) ?? null,
      })),
      liveDocumentIds);
  }
  return out;
}

/**
 * Build the run's dependencies against live Firestore and NOAA.
 *
 * `writeDocument` re-reads inside a transaction and re-applies shouldWrite, so
 * the supersession decision is made under lock. The pure `runStoreUpdate` still
 * calls `readExisting` first; that read is an optimisation that avoids fetching
 * work, and the transaction is what makes the decision correct.
 *
 * @param {object} io - Upstream fetchers, injected so tests never hit NOAA.
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {StoreRunDeps} Dependencies for runStoreUpdate.
 */
export function firestoreDeps(
  io: {
    fetchProduct(
      source: ForecastSourceId,
      reachId: string,
      product: ForecastProductId,
    ): Promise<FetchedProduct>;
  },
  usage: FirestoreUsage
): StoreRunDeps {
  return {
    async readExisting(documentId: string): Promise<StoreDocument | null> {
      try {
        const snap = await db.collection(STORE_COLLECTION).doc(documentId)
          .get();
        usage.reads++;
        return snap.exists ? (snap.data() as StoreDocument) : null;
      } catch (e) {
        // Losing the database is not this reach's problem.
        throw new FatalRunError("Firestore read failed", e);
      }
    },

    async writeDocument(documentId: string, doc: StoreDocument): Promise<void> {
      // Trim and size-check before the transaction: an oversized document must
      // fail this reach, not abort a transaction that has taken a lock.
      const trimmed = {
        ...doc,
        payload: trimPayload(doc.product, doc.payload),
      };
      assertPayloadFits(documentId, trimmed.payload);

      const ref = db.collection(STORE_COLLECTION).doc(documentId);
      try {
        let committed = false;
        await db.runTransaction(async (tx) => {
          const snap = await tx.get(ref);
          // Billed, and previously uncounted: a second read per planned write.
          usage.reads++;
          const current = snap.exists ?
            (snap.data() as StoreDocument) :
            null;
          // Re-checked UNDER LOCK. The caller's earlier readExisting may be
          // stale by now: another run can have written between that read and
          // this transaction, and without this the older run would win.
          if (!shouldWrite(current, trimmed)) {
            logger.info("↩️ store: a concurrent run already wrote newer data", {
              documentId,
              storedRun: current?.runId ?? null,
              incomingRun: trimmed.runId ?? null,
            });
            return;
          }
          tx.set(ref, trimmed);
          committed = true;
        });
        // Only a real commit is a write. Counting refusals inflated the figure
        // guard 11 reports and made it disagree with report.written by
        // construction. Round 2, F4.
        if (committed) usage.writes++;
      } catch (e) {
        if (e instanceof Error && /PERMISSION_DENIED|UNAUTHENTICATED/
          .test(e.message)) {
          throw new FatalRunError("Firestore write denied", e);
        }
        throw e;
      }
    },

    fetchProduct: io.fetchProduct,
    now: () => new Date(),
  };
}

/**
 * Every stored document's ID and fetch time, for the GC.
 *
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<{documentId: string, fetchedAt: string}[]>} The listing.
 */
export async function listStoredDocuments(
  usage: FirestoreUsage
): Promise<{documentId: string; fetchedAt: string}[]> {
  const snap = await db.collection(STORE_COLLECTION)
    .select("window").get();
  usage.reads += snap.size;
  return snap.docs.map((d) => ({
    documentId: d.id,
    fetchedAt: (d.data().window?.fetchedAt as string) ?? "",
  }));
}

/**
 * Read the window fields of every stored document for the given products.
 *
 * Selects only what the window decision needs — Firestore still bills a read
 * per document, but the payloads (which are the large part) never leave the
 * server.
 *
 * @param {readonly ForecastProductId[]} products - Products to sample.
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<StoredWindowSample[]>} One sample per document.
 */
export async function sampleStoredWindows(
  products: readonly ForecastProductId[],
  usage: FirestoreUsage
): Promise<StoredWindowSample[]> {
  const samples: StoredWindowSample[] = [];
  for (const product of products) {
    const snap = await db.collection(STORE_COLLECTION)
      .where("product", "==", product)
      .select("source", "reachId", "product", "window", "runId")
      .get();
    usage.reads += snap.size;
    for (const d of snap.docs) {
      samples.push(windowSampleFrom(d.id, d.data()));
    }
  }
  return samples;
}

/**
 * One stored document, as the window planner needs to see it.
 *
 * **Extracted so the mapping is testable at all.** It used to be inline in the
 * Firestore loop, which needs an emulator this suite does not run — so
 * dropping `reachId` here passed all 442 tests while making every island
 * document fall back to CONUS caps. Found by the Phase 9 review, which
 * mutated exactly this line.
 *
 * The fields are not interchangeable: `reachId` decides which hold and
 * run-age cap the document is judged by, and an empty one is silently CONUS.
 *
 * @param {string} documentId - The Firestore document id.
 * @param {Record<string, unknown>} data - Its selected fields.
 * @return {StoredWindowSample} The sample.
 */
export function windowSampleFrom(
  documentId: string,
  data: Record<string, unknown>
): StoredWindowSample {
  const window = (data.window ?? {}) as Record<string, unknown>;
  return {
    documentId,
    source: data.source as ForecastSourceId,
    reachId: (data.reachId as string) ?? "",
    product: data.product as ForecastProductId,
    fetchedAt: (window.fetchedAt as string) ?? "",
    validUntil: (window.validUntil as string) ?? "",
    runId: data.runId as string | undefined,
  };
}

/**
 * Re-stamp `window.validUntil` on documents the plan selected.
 *
 * Deliberately a field update, not a document write: the payload, the run and
 * `fetchedAt` are untouched, so this cannot be mistaken for new data and
 * cannot move supersession. `fetchedAt` in particular MUST stay put — it is
 * what the hold cap is measured from, and refreshing it here would let a
 * document be held forever one extension at a time.
 *
 * @param {readonly WindowExtension[]} extensions - Windows to re-stamp.
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<number>} How many documents were updated.
 */
export async function applyWindowExtensions(
  extensions: readonly WindowExtension[],
  usage: FirestoreUsage
): Promise<number> {
  let updated = 0;
  const CHUNK = 200;
  for (let i = 0; i < extensions.length; i += CHUNK) {
    const batch = db.batch();
    for (const e of extensions.slice(i, i + CHUNK)) {
      batch.update(
        db.collection(STORE_COLLECTION).doc(e.documentId),
        {"window.validUntil": e.validUntil});
    }
    await batch.commit();
    updated += Math.min(CHUNK, extensions.length - i);
  }
  usage.writes += updated;
  return updated;
}

/**
 * Delete documents the GC selected.
 *
 * Takes IDs already vetted by selectGarbage AND assertGcSane; it deliberately
 * re-runs neither, so that the destructive step has exactly one caller and the
 * decision to delete is never made here.
 *
 * @param {string[]} documentIds - Vetted IDs.
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<number>} How many were deleted.
 */
export async function deleteDocuments(
  documentIds: string[],
  usage: FirestoreUsage
): Promise<number> {
  let deleted = 0;
  // Batched, but capped well under Firestore's 500-op limit.
  const CHUNK = 200;
  for (let i = 0; i < documentIds.length; i += CHUNK) {
    const batch = db.batch();
    for (const id of documentIds.slice(i, i + CHUNK)) {
      batch.delete(db.collection(STORE_COLLECTION).doc(id));
    }
    await batch.commit();
    deleted += Math.min(CHUNK, documentIds.length - i);
  }
  usage.deletes += deleted;
  return deleted;
}

/**
 * When the store was last written successfully, for the heartbeat.
 *
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<Date | null>} Timestamp, or null when the store is empty.
 */
export async function lastSuccessfulWrite(
  usage: FirestoreUsage
): Promise<Date | null> {
  const snap = await db.collection(STORE_COLLECTION)
    .orderBy("window.fetchedAt", "desc").limit(1).get();
  usage.reads += snap.size;
  if (snap.empty) return null;
  const at = snap.docs[0].data().window?.fetchedAt as string | undefined;
  if (!at) return null;
  const d = new Date(at);
  return Number.isNaN(d.getTime()) ? null : d;
}
