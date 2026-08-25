// functions/src/store-service.ts
//
// ADR 0011 Phase 4: the entry points. Everything below is assembly — the
// decisions live in the pure modules and are tested there.
//
// Three ways the store changes:
//   1. `runStoreRefresh` — hourly. Reads the probe, decides what advanced,
//      refreshes the work list for those products. Guard 1 means this does
//      nothing at all when nothing advanced.
//   2. `runStoreWriteThrough` — a single reach, on demand. Guard 9: favouriting
//      a never-viewed reach must produce a document within seconds, not at the
//      next hourly tick.
//   3. `runStoreGc` — daily. Guard 7.

import * as logger from "firebase-functions/logger";

import {
  FetchedProduct,
  PRODUCTS_BY_SOURCE,
  StoreRunReport,
  runStoreUpdate,
} from "./store-run.js";
import {
  assessStoreHealth,
  decideTriggers,
  quotaUsage,
} from "./store-trigger.js";
import {
  FirestoreUsage,
  deleteDocuments,
  firestoreDeps,
  lastSuccessfulWrite,
  listStoredDocuments,
  newUsage,
  readAllUsers,
  readLatestProbe,
  sampleStoredRun,
} from "./store-firestore.js";
import {assertGcSane, selectGarbage} from "./store-gc.js";
import {ForecastProductId, ForecastSourceId} from "./store-keys.js";
import {
  WorkList,
  assertWorkListConsistent,
  deriveWorkList,
} from "./store-work-list.js";

/** Products the store keeps fresh on the hourly cycle. */
export const MANAGED_PRODUCTS: readonly ForecastProductId[] = [
  "analysisAssimilation",
  "shortRange",
  "mediumRange",
  "longRange",
];

/**
 * GEOGLOWS publishes once per UTC day, so it is not driven by the NWM probe.
 * ADR Build: "GEOGLOWS on its own daily schedule, keyed on forecast_date."
 */
export const GEOGLOWS_PRODUCTS: readonly ForecastProductId[] =
  ["geoglowsForecast"];

/** Upstream fetchers, injected so nothing here reaches NOAA during tests. */
export interface UpstreamIo {
  fetchProduct(
    source: ForecastSourceId,
    reachId: string,
    product: ForecastProductId,
  ): Promise<FetchedProduct>;
}

export interface RefreshOutcome {
  ran: boolean;
  reason: string;
  report: StoreRunReport | null;
  usage: FirestoreUsage;
}

/**
 * Read every user and derive the deduplicated work list, asserting as it goes.
 *
 * @param {FirestoreUsage} usage - Counters to increment.
 * @return {Promise<WorkList>} The work list.
 */
async function buildWorkList(usage: FirestoreUsage): Promise<WorkList> {
  const users = await readAllUsers(usage);
  const workList = deriveWorkList(users);
  assertWorkListConsistent(workList, users.length);
  return workList;
}

/**
 * The hourly refresh.
 *
 * @param {UpstreamIo} io - Upstream fetchers.
 * @param {ForecastProductId[]} candidates - Products to consider.
 * @return {Promise<RefreshOutcome>} What happened.
 */
export async function runStoreRefresh(
  io: UpstreamIo,
  candidates: readonly ForecastProductId[] = MANAGED_PRODUCTS
): Promise<RefreshOutcome> {
  const usage = newUsage();

  const probe = await readLatestProbe(usage);
  if (!probe) {
    // Without the probe there is no evidence upstream advanced, and fetching
    // to find out is the cost guard 1 forbids.
    return {
      ran: false,
      reason: "no probe sample available; refusing to fetch blind",
      report: null,
      usage,
    };
  }

  const stored: Partial<Record<ForecastProductId, string | null>> = {};
  for (const p of candidates) stored[p] = await sampleStoredRun(p, usage);

  const decision = decideTriggers(probe, stored, candidates);
  logger.info("🧭 store refresh: trigger decision", {
    triggered: decision.triggered,
    reasons: decision.reasons,
  });

  if (decision.triggered.length === 0) {
    return {
      ran: false,
      reason: "nothing advanced upstream",
      report: null,
      usage,
    };
  }

  const workList = await buildWorkList(usage);
  const report = await runStoreUpdate(
    workList, decision.triggered, firestoreDeps(io, usage));

  const quota = quotaUsage(usage.reads, usage.writes);
  logger.info("📊 store refresh: Firestore usage vs documented free tier", {
    ...quota,
    reachesToRetry: report.reachesToRetry.length,
  });

  return {ran: true, reason: "upstream advanced", report, usage};
}

/**
 * Refresh one reach immediately (guard 9).
 *
 * Deliberately skips the probe: the reason to run is that a user just
 * favourited this reach, not that upstream moved, and waiting up to an hour
 * for the next tick is the experience this exists to avoid. It refreshes one
 * reach only, so it cannot become a back door to a full fan-out.
 *
 * @param {UpstreamIo} io - Upstream fetchers.
 * @param {ForecastSourceId} source - The reach's network.
 * @param {string} reachId - The reach.
 * @return {Promise<RefreshOutcome>} What happened.
 */
export async function runStoreWriteThrough(
  io: UpstreamIo,
  source: ForecastSourceId,
  reachId: string
): Promise<RefreshOutcome> {
  const usage = newUsage();

  const workList: WorkList = {
    entries: [{
      source,
      reachId,
      dedupeKey: `${source}:${reachId}`,
      followerCount: 1,
    }],
    summary: {
      usersScanned: 0,
      usersWithFavourites: 0,
      favouriteRowsSeen: 1,
      favouriteRowsRejected: 0,
      distinctReaches: 1,
      bySource: {
        nwm: source === "nwm" ? 1 : 0,
        geoglows: source === "geoglows" ? 1 : 0,
      },
    },
  };

  const products = PRODUCTS_BY_SOURCE[source];
  const report = await runStoreUpdate(
    workList, products, firestoreDeps(io, usage));

  logger.info("⚡ store write-through complete", {
    source,
    reachId,
    written: report.written,
    failed: report.failed,
  });
  return {ran: true, reason: "write-through on favourite", report, usage};
}

export interface GcOutcome {
  scanned: number;
  deleted: number;
  refused: string | null;
  usage: FirestoreUsage;
}

/**
 * The daily garbage collection (guard 7).
 *
 * selectGarbage decides, assertGcSane vets, and only then does anything get
 * deleted. The vetting is not optional and not inside the selector, so the one
 * destructive call has the refusal directly above it.
 *
 * @return {Promise<GcOutcome>} What was removed, or why nothing was.
 */
export async function runStoreGc(): Promise<GcOutcome> {
  const usage = newUsage();
  const workList = await buildWorkList(usage);
  const stored = await listStoredDocuments(usage);

  const decision = selectGarbage(workList, stored, new Date());

  try {
    assertGcSane(decision, workList);
  } catch (e) {
    // Refusing is the correct outcome, not an error to swallow. Logged at
    // error level because a refusal means something upstream of the GC is
    // wrong — usually the user query.
    const message = e instanceof Error ? e.message : String(e);
    logger.error("🛑 store GC refused", {message});
    return {scanned: decision.scanned, deleted: 0, refused: message, usage};
  }

  const deleted = await deleteDocuments(
    decision.toDelete.map((c) => c.documentId), usage);

  logger.info("🧹 store GC complete", {
    scanned: decision.scanned,
    deleted,
    retained: decision.retained.length,
  });
  return {scanned: decision.scanned, deleted, refused: null, usage};
}

/**
 * The heartbeat (ADR: "a heartbeat alerting when no successful write lands in
 * N hours").
 *
 * @return {Promise<{status: string, problems: string[]}>} Health.
 */
export async function checkStoreHealth(): Promise<{
  status: string;
  problems: string[];
}> {
  const usage = newUsage();
  const [lastWrite, probe] = await Promise.all([
    lastSuccessfulWrite(usage),
    readLatestProbe(usage),
  ]);

  const health = assessStoreHealth(
    lastWrite, probe?.sampledAt ?? null, new Date());

  if (health.status === "healthy") {
    logger.info("💚 store healthy", {
      lastWriteAgeMs: health.lastWriteAgeMs,
    });
  } else {
    // error level so it surfaces without anybody watching, which is the
    // "with nobody watching" half of the phase's done-when.
    logger.error(`🚨 store ${health.status}`, {problems: health.problems});
  }
  return {status: health.status, problems: health.problems};
}
