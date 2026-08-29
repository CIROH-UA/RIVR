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
import {ProbeRuns} from "./store-trigger.js";

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
 * The run currently stored for a product, sampled from ONE document.
 *
 * Reaches can legitimately sit on different runs (guard 3), so there is no
 * single "the store's run". This samples the first document found for the
 * product and is used only to decide whether upstream has moved — a reach
 * still behind is caught per-reach by the supersession check.
 *
 * @param {ForecastProductId} product - Product to sample.
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<string | null>} A stored run, or null.
 */
export async function sampleStoredRun(
  product: ForecastProductId,
  usage: FirestoreUsage
): Promise<string | null> {
  // ASCENDING: the OLDEST run wins. Sampling the newest meant one reach
  // writing the current run made the next hour report "unchanged", so a reach
  // still behind was never revisited — for medium/long range, up to six hours
  // stale with no failure and no log. Round 2, F1 follow-on.
  const snap = await db.collection(STORE_COLLECTION)
    .where("product", "==", product)
    .orderBy("runId", "asc")
    .limit(1)
    .get();
  usage.reads += snap.size;
  if (snap.empty) return null;
  return (snap.docs[0].data().runId as string | undefined) ?? null;
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
      .select("source", "product", "window")
      .get();
    usage.reads += snap.size;
    for (const d of snap.docs) {
      const data = d.data();
      samples.push({
        documentId: d.id,
        source: data.source as ForecastSourceId,
        product: data.product as ForecastProductId,
        fetchedAt: (data.window?.fetchedAt as string) ?? "",
        validUntil: (data.window?.validUntil as string) ?? "",
      });
    }
  }
  return samples;
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
