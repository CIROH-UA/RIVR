// functions/src/store-trigger.ts
//
// ADR 0011 Phase 4 Build: "Hourly probe decides when to try; on advance, fetch
// the affected products for every reach in the derived work list."
//
// This is the piece guard 1 rests on — "no new run -> ZERO fetches beyond the
// probe". The decision must be made from data the probe ALREADY collected and
// from what is already stored. Fetching upstream to find out whether upstream
// changed is exactly the cost the phase exists to remove, so nothing here
// touches the network.
//
// The probe writes one document per hour into `publish_cadence_log` carrying
// `referenceTimes`, keyed by product id — the same identifiers used for
// ForecastProduct, so no translation layer is needed or wanted.

import {ForecastProductId} from "./store-keys.js";
import {isRunNewer} from "./store-document.js";

/** The probe's view of what upstream has published. */
export interface ProbeRuns {
  /** product id -> referenceTime, or null when that endpoint gave none. */
  referenceTimes: Record<string, string | null>;
  /** When the probe sampled. Used to detect a stalled probe. */
  sampledAt: Date;
}

/**
 * Which probe key actually describes each product's stored run.
 *
 * These are not always the same name. The store's `analysisAssimilation`
 * document holds a SHORT RANGE body with a shortRange run, because that is
 * what the client derives current flow from. The probe's
 * `analysisAssimilation` key, however, comes from NOAA's
 * `?series=analysis_assimilation` endpoint — a genuinely different series,
 * measured ~3 hours behind short range.
 *
 * Comparing them directly made the product stop triggering after its first
 * write: `isRunNewer(AA 20:00Z, stored SR 23:00Z)` is false, so it read
 * "unchanged" for hours while its own validUntil expired every hour. Round 3,
 * B3.
 */
export const PROBE_KEY_BY_PRODUCT: Partial<Record<ForecastProductId, string>> =
  {
    analysisAssimilation: "shortRange",
  };

/** The probe run to compare a product's stored run against. */
export function probeRunFor(
  probe: ProbeRuns,
  product: ForecastProductId
): string | null {
  const key = PROBE_KEY_BY_PRODUCT[product] ?? product;
  return probe.referenceTimes[key] ?? null;
}

/** What the store currently holds, per product. */
export type StoredRuns = Partial<Record<ForecastProductId, string | null>>;

export interface TriggerDecision {
  /** Products to refresh this run. Empty means do nothing at all. */
  triggered: ForecastProductId[];
  /** Why each product was or was not triggered — auditable, not silent. */
  reasons: Record<string, string>;
}

/** One document's run identity, as sampled for the trigger decision. */
export interface RunSample {
  documentId: string;
  runId: string | null;
}

/**
 * The oldest run among documents a refresh run could actually update.
 *
 * Ascending — the OLDEST live run wins — for the reason the original sample
 * did: one reach writing the current run must not make the next hour report
 * "unchanged" while another followed reach is still behind.
 *
 * The restriction to live documents is the 2026-08-29 fix. Orphaned documents
 * from unfavourited reaches sit in the collection for the GC's seven-day grace
 * and are never rewritten, so their run identity is frozen. Including them
 * pinned the sample in the past and made every product read as "upstream
 * advanced" every single hour.
 *
 * @param {readonly RunSample[]} samples - Every document of one product.
 * @param {ReadonlySet<string>} liveDocumentIds - IDs the work list covers.
 * @return {string | null} The oldest live run, or null when the store holds
 *   nothing live for this product.
 */
export function oldestLiveRun(
  samples: readonly RunSample[],
  liveDocumentIds: ReadonlySet<string>
): string | null {
  let oldest: string | null = null;
  let sawLive = false;
  for (const s of samples) {
    if (!liveDocumentIds.has(s.documentId)) continue;
    sawLive = true;
    // A live document with no run identity cannot be ordered. It is not a
    // candidate for "oldest", but it must not read as "nothing stored"
    // either — that would trigger a full fan-out.
    if (s.runId === null) continue;
    if (oldest === null || isRunNewer(oldest, s.runId)) oldest = s.runId;
  }
  return sawLive ? oldest : null;
}

/**
 * Products whose upstream run has moved past what the store holds.
 *
 * A product triggers when the probe reports a run and either the store has
 * none, or the probe's run is strictly newer. It does NOT trigger when the
 * probe reports nothing (that endpoint failed this hour — treating a failed
 * probe as "new data" would fetch every reach on every probe outage) or when
 * the runs match.
 *
 * @param {ProbeRuns} probe - The latest probe sample.
 * @param {StoredRuns} stored - Runs currently in the store, per product.
 * @param {ForecastProductId[]} candidates - Products the store manages.
 * @return {TriggerDecision} What to refresh, and why.
 */
export function decideTriggers(
  probe: ProbeRuns,
  stored: StoredRuns,
  candidates: readonly ForecastProductId[]
): TriggerDecision {
  const decision: TriggerDecision = {triggered: [], reasons: {}};

  for (const product of candidates) {
    // Not probe.referenceTimes[product] — see PROBE_KEY_BY_PRODUCT.
    const upstream = probeRunFor(probe, product);
    const held = stored[product] ?? null;

    if (upstream === null) {
      // The probe deliberately does not retry, so a null here is a real
      // upstream failure this hour. Refetching everything on it would turn
      // every outage into a full fan-out.
      decision.reasons[product] = "probe reported no run this hour";
      continue;
    }
    if (held === null) {
      decision.triggered.push(product);
      decision.reasons[product] = `store holds nothing; upstream ${upstream}`;
      continue;
    }
    if (isRunNewer(upstream, held)) {
      decision.triggered.push(product);
      decision.reasons[product] = `upstream ${upstream} newer than ${held}`;
      continue;
    }
    decision.reasons[product] = `unchanged at ${held}`;
  }

  return decision;
}

/**
 * How long the store may go without a successful write before something is
 * wrong.
 *
 * PROVISIONAL. Derived from the publish cadence rather than measured: the
 * slowest product the store carries is the 6-hourly medium/long range, so a
 * healthy store writes at least once per 6-hour cycle plus slack. Phase 0
 * guard 2 (seven consecutive days of publication lag, expected ~2026-08-31)
 * must confirm or replace this number.
 */
export const HEARTBEAT_STALE_MS = 8 * 60 * 60 * 1000;

/** How stale the PROBE itself may be before its runs are untrustworthy. */
export const PROBE_STALE_MS = 3 * 60 * 60 * 1000;

export type HealthStatus = "healthy" | "degraded" | "down";

export interface StoreHealth {
  status: HealthStatus;
  /** Every problem found, not just the first. */
  problems: string[];
  lastWriteAgeMs: number | null;
  probeAgeMs: number | null;
}

/**
 * Assess whether the store is actually working.
 *
 * ADR 0011 Phase 4: monitoring ships in this phase, and "is the store fresh
 * right now?" must be answerable. The specific failure this catches is the one
 * the ADR names as impossible to see otherwise: a run that keeps exiting 0
 * while writing nothing. No successful write for hours is indistinguishable
 * from a quiet upstream unless something checks.
 *
 * @param {Date | null} lastSuccessfulWrite - Most recent store write.
 * @param {Date | null} lastProbeSample - Most recent probe sample.
 * @param {Date} now - Reference instant.
 * @return {StoreHealth} Status plus every problem found.
 */
export function assessStoreHealth(
  lastSuccessfulWrite: Date | null,
  lastProbeSample: Date | null,
  now: Date
): StoreHealth {
  const problems: string[] = [];

  const lastWriteAgeMs = lastSuccessfulWrite ?
    now.getTime() - lastSuccessfulWrite.getTime() :
    null;
  const probeAgeMs = lastProbeSample ?
    now.getTime() - lastProbeSample.getTime() :
    null;

  if (lastWriteAgeMs === null) {
    problems.push("the store has never been written to");
  } else if (lastWriteAgeMs > HEARTBEAT_STALE_MS) {
    problems.push(
      `no successful write for ${Math.round(lastWriteAgeMs / 3600_000)}h ` +
      `(threshold ${HEARTBEAT_STALE_MS / 3600_000}h)`
    );
  }

  if (probeAgeMs === null) {
    problems.push("no probe sample has ever been recorded");
  } else if (probeAgeMs > PROBE_STALE_MS) {
    // Without a live probe the store cannot tell whether upstream advanced,
    // so it would sit still and look healthy while going stale.
    problems.push(
      `probe last sampled ${Math.round(probeAgeMs / 3600_000)}h ago ` +
      `(threshold ${PROBE_STALE_MS / 3600_000}h)`
    );
  }

  let status: HealthStatus = "healthy";
  if (problems.length === 1) status = "degraded";
  if (problems.length > 1) status = "down";
  if (lastWriteAgeMs === null && probeAgeMs === null) status = "down";

  return {status, problems, lastWriteAgeMs, probeAgeMs};
}

/**
 * Firestore's documented free-tier daily allowances.
 *
 * Guard 11 asks for reads/writes per day measured against these. Noted here as
 * documentation, not as a limit the code enforces: the project is on Blaze,
 * where these are a reference point rather than a cap (ADR 0010 carries the
 * same caveat).
 */
export const FREE_TIER_READS_PER_DAY = 50_000;
export const FREE_TIER_WRITES_PER_DAY = 20_000;

export interface QuotaUsage {
  reads: number;
  writes: number;
  readsPctOfFree: number;
  writesPctOfFree: number;
}

/**
 * Express a run's Firestore usage against the documented free tier.
 *
 * @param {number} reads - Documents read.
 * @param {number} writes - Documents written.
 * @return {QuotaUsage} Counts plus their share of the daily allowance.
 */
export function quotaUsage(reads: number, writes: number): QuotaUsage {
  return {
    reads,
    writes,
    readsPctOfFree: (reads / FREE_TIER_READS_PER_DAY) * 100,
    writesPctOfFree: (writes / FREE_TIER_WRITES_PER_DAY) * 100,
  };
}
