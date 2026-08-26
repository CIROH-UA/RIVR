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
  StoreRunAssertionError,
  StoreRunReport,
  runStoreUpdate,
} from "./store-run.js";
import {
  assessStoreHealth,
  decideTriggers,
  probeRunFor,
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
import {StoreDocument} from "./store-document.js";
import {
  ForecastProductId,
  ForecastSourceId,
  storageKey,
} from "./store-keys.js";
import {canFetch} from "./store-upstream.js";
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
 * GEOGLOWS publishes one run per UTC day, so it is NOT driven by the NWM
 * probe. ADR Build: "GEOGLOWS on its own daily schedule, keyed on
 * forecast_date." The run identity IS that date, so supersession still works:
 * a second run on the same day is skipped as same-run.
 */
export const GEOGLOWS_PRODUCTS: readonly ForecastProductId[] =
  ["geoglowsForecast"];

/**
 * The near-static NWM products: a river's name and its flood thresholds.
 *
 * Kept OUT of MANAGED_PRODUCTS deliberately. They carry no run identity, so
 * the probe has nothing to compare and `decideTriggers` could never fire them;
 * and they hold a 30-day freshness window, so putting them on the hourly cycle
 * would refetch an unchanging river name 24 times a day per favourite.
 *
 * They exist in the store because Phase 5 guard 1 is "a favourite renders with
 * ZERO upstream calls from the device", and every surface that renders a
 * favourite reads its name and its thresholds. Without these two products the
 * hourly cycle keeps the flow numbers fresh while each favourite still makes
 * two device-side calls to render at all — the store present, and the guard
 * unreachable. Phase 5 review round 1 found exactly that.
 */
export const STATIC_PRODUCTS: readonly ForecastProductId[] = [
  "reachMetadata",
  "returnPeriods",
];

/**
 * Refresh a static product this long before it expires.
 *
 * Not zero. A document refreshed only once already stale leaves a window in
 * which every device sees it as expired and falls back to fetching upstream —
 * silently undoing guard 1 for a day, once a month, with nothing in any log to
 * say so. Seven days of lead on a 30-day window means the daily pass has 7
 * chances to succeed before any device notices.
 */
export const STATIC_REFRESH_LEAD_MS = 7 * 24 * 3600_000;

/**
 * Whether a static document must be refetched now.
 *
 * Pure, and separated from the run so the decision is testable without
 * Firestore — the same reason deriveWorkList, planWrites and shouldWrite are
 * pure. It is the whole cost story of the daily pass: return false and the
 * pass performs a read and no fetch.
 *
 * Refetches when there is no document, when the window is missing or
 * unparseable, or when it expires within {@link STATIC_REFRESH_LEAD_MS}. An
 * unreadable window is NOT evidence of freshness: trusting it would leave a
 * document that can never be renewed, and the device would fall back to
 * fetching upstream forever with nothing in any log.
 *
 * @param {StoreDocument | null} existing - The stored document, if any.
 * @param {Date} now - Reference instant.
 * @return {boolean} True when the product should be refetched.
 */
export function staticRefreshDue(
  existing: StoreDocument | null,
  now: Date
): boolean {
  const validUntil = existing?.window?.validUntil;
  if (typeof validUntil !== "string") return true;
  const expiresAt = Date.parse(validUntil);
  if (Number.isNaN(expiresAt)) return true;
  return expiresAt <= now.getTime() + STATIC_REFRESH_LEAD_MS;
}

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
  // The probe's runs go in so guard 3 can tell a lagging reach from a settled
  // one — see lagsProbe.
  // Remapped, for the same reason decideTriggers remaps: handing the raw
  // probe keys to lagsProbe would compare a product's stored run against a
  // different NOAA series.
  const probeRuns: Partial<Record<ForecastProductId, string | null>> = {};
  for (const p of decision.triggered) probeRuns[p] = probeRunFor(probe, p);

  const report = await runStoreUpdate(
    workList, decision.triggered, firestoreDeps(io, usage), probeRuns);

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

  // Only what upstream can actually serve. Planning the full
  // PRODUCTS_BY_SOURCE set meant every NWM favourite recorded two guaranteed
  // failures, and every GEOGLOWS favourite produced nothing at all while
  // reporting a failure. Round 2, F3.
  const products = PRODUCTS_BY_SOURCE[source].filter(
    (p) => canFetch(source, p));

  if (products.length === 0) {
    logger.info("⏭️ write-through skipped: nothing fetchable for this source", {
      source, reachId,
    });
    return {
      ran: false,
      reason: `no fetchable products for ${source}`,
      report: null,
      usage,
    };
  }

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

/**
 * The daily GEOGLOWS refresh.
 *
 * No probe gate: GEOGLOWS has no hourly probe, and its once-daily cadence is
 * the schedule itself. Supersession still prevents redundant writes — a run
 * carrying the forecast_date already stored is skipped as same-run, so running
 * twice in a day costs reads, not writes.
 *
 * @param {UpstreamIo} io - Upstream fetchers.
 * @return {Promise<RefreshOutcome>} What happened.
 */
export async function runGeoglowsRefresh(
  io: UpstreamIo
): Promise<RefreshOutcome> {
  const usage = newUsage();
  const full = await buildWorkList(usage);

  // Only the GEOGLOWS reaches. Passing the whole work list would plan
  // geoglowsForecast for NWM reaches, which planWrites drops anyway — but
  // filtering here keeps the reported counts about GEOGLOWS.
  const workList: WorkList = {
    entries: full.entries.filter((e) => e.source === "geoglows"),
    summary: full.summary,
  };

  if (workList.entries.length === 0) {
    logger.info("🟰 GEOGLOWS refresh: nobody follows a GEOGLOWS reach");
    return {ran: false, reason: "no GEOGLOWS reaches followed", report: null,
      usage};
  }

  const report = await runStoreUpdate(
    workList, GEOGLOWS_PRODUCTS, firestoreDeps(io, usage));

  const quota = quotaUsage(usage.reads, usage.writes);
  logger.info("📊 GEOGLOWS refresh: Firestore usage vs free tier", {
    ...quota,
    written: report.written,
    failed: report.failed,
  });
  return {ran: true, reason: "daily GEOGLOWS run", report, usage};
}

export interface GcOutcome {
  scanned: number;
  deleted: number;
  refused: string | null;
  usage: FirestoreUsage;
}

/**
 * The daily refresh of the near-static products (Phase 5 guard 1).
 *
 * Unlike the hourly refresh this is NOT probe-driven — there is no run to
 * advance — so "has it changed?" is unanswerable without fetching, and
 * fetching every reach every day to find out is the cost guard 1 forbids.
 * Instead the decision is made on the stored freshness window: a document is
 * refetched only when it is missing, unreadable, or within
 * {@link STATIC_REFRESH_LEAD_MS} of expiring. On a steady state that is one
 * Firestore READ per reach per product per day and no fetch at all.
 *
 * Read cost, stated in full rather than rounded in our favour: 2 reads per
 * favourited reach per day for the freshness checks, PLUS one `readAllUsers`
 * scan per run (~18 documents today), PLUS a second read of each DUE document
 * inside `runStoreUpdate`'s supersession check. Steady state at the ADR's
 * current scale is under a hundred reads a day against a 50,000/day free tier.
 * An earlier version of this sentence claimed the 2-per-reach figure was the
 * whole cost; review round 3 pointed out it was the whole cost only of the
 * loop directly below it.
 *
 * NWM only. GEOGLOWS reaches carry no NOAA metadata or NWM thresholds; its
 * forecast payload already carries its own return periods.
 *
 * @param {UpstreamIo} io - Upstream fetchers.
 * @return {Promise<RefreshOutcome>} What happened.
 */
export async function runStoreStaticRefresh(
  io: UpstreamIo
): Promise<RefreshOutcome> {
  const usage = newUsage();
  const deps = firestoreDeps(io, usage);
  const now = deps.now();

  const workList = await buildWorkList(usage);
  const nwm = workList.entries.filter((e) => e.source === "nwm");

  if (nwm.length === 0) {
    return {
      ran: false,
      reason: "no NWM favourites; nothing static to refresh",
      report: null,
      usage,
    };
  }

  const merged: StoreRunReport = {
    productsTriggered: [],
    planned: 0,
    written: 0,
    skippedSameRun: 0,
    skippedLagging: 0,
    failed: 0,
    reachesToRetry: [],
    results: [],
    fetches: 0,
  };

  for (const product of STATIC_PRODUCTS) {
    if (!canFetch("nwm", product)) continue;

    const due: typeof nwm = [];
    for (const entry of nwm) {
      const id = storageKey("nwm", entry.reachId, product);
      const existing = await deps.readExisting(id);
      if (staticRefreshDue(existing, now)) due.push(entry);
    }

    if (due.length === 0) {
      logger.info("⏭️ static refresh: all current", {
        product, reaches: nwm.length,
      });
      continue;
    }

    const scoped: WorkList = {
      entries: due,
      summary: {
        ...workList.summary,
        distinctReaches: due.length,
        bySource: {nwm: due.length, geoglows: 0},
      },
    };

    const report = await runStoreUpdate(scoped, [product], deps);

    merged.productsTriggered.push(product);
    merged.planned += report.planned;
    merged.written += report.written;
    merged.skippedSameRun += report.skippedSameRun;
    merged.skippedLagging += report.skippedLagging;
    merged.failed += report.failed;
    merged.fetches += report.fetches;
    merged.results.push(...report.results);
    for (const r of report.reachesToRetry) {
      if (!merged.reachesToRetry.includes(r)) merged.reachesToRetry.push(r);
    }
  }

  // Counts, asserted — not an exit status. CLAUDE.md's non-negotiable for
  // these pipelines is that they fail SILENTLY, and the first deployed run of
  // this very function proved it again: it reported "ok" while failing 3 of 29
  // reaches, caught only because a human read the document counts back out of
  // Firestore. Review round 6 pointed out the fetcher was fixed and the
  // REPORTING hole that let it pass was not.
  if (merged.written + merged.failed !== merged.planned) {
    throw new StoreRunAssertionError(
      `static refresh planned ${merged.planned} writes but accounted for ` +
      `${merged.written} written + ${merged.failed} failed — the run lost ` +
      "work it never reported"
    );
  }

  // A failure is never an INFO-level detail here: every one is a reach whose
  // river name or flood thresholds are now up to 30 days stale on device.
  if (merged.failed > 0) {
    logger.error("🚨 static refresh FAILED for some reaches", {
      failed: merged.failed,
      planned: merged.planned,
      written: merged.written,
      reaches: merged.results
        .filter((r) => r.outcome === "failed")
        .map((r) => r.documentId),
    });
  }

  logger.info("🪨 static refresh complete", {
    products: merged.productsTriggered,
    planned: merged.planned,
    written: merged.written,
    failed: merged.failed,
    reads: usage.reads,
  });

  if (merged.planned === 0) {
    return {
      ran: false,
      reason: "every static document is still current",
      report: merged,
      usage,
    };
  }
  return {ran: true, reason: "static products due for refresh", report: merged,
    usage};
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
