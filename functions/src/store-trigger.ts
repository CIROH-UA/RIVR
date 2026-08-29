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
import {
  StoredWindowSample,
  maxHoldMs,
  maxRunAgeMs,
} from "./store-window.js";

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
  /** Per-product freshness, stalest first. Empty when not supplied. */
  products: ProductFreshness[];
  /** Per-product run currency, stalest first. Empty when not supplied. */
  runs: ProductRunCurrency[];
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
 * The collection-wide write age stays as a coarse "is anything happening at
 * all" check; `samples` adds the per-product dimension that catches ONE product
 * stalling while the others keep the aggregate looking fresh. Optional so a
 * caller wanting only the coarse answer keeps working.
 *
 * @param {Date | null} lastSuccessfulWrite - Most recent store write.
 * @param {Date | null} lastProbeSample - Most recent probe sample.
 * @param {Date} now - Reference instant.
 * @param {readonly StoredWindowSample[]} samples - Every stored document.
 * @return {StoreHealth} Status plus every problem found.
 */
/** One product's freshness, as the health check sees it. */
export interface ProductFreshness {
  product: ForecastProductId;
  /** Age of the NEWEST document for this product. */
  ageMs: number;
  /** The product's hold cap — past this, silence means broken. */
  capMs: number;
  stale: boolean;
}

/**
 * Assess freshness PER PRODUCT.
 *
 * **Why this exists.** `lastSuccessfulWrite` takes the newest write across the
 * WHOLE collection, so one fresh NWM hourly write makes the store look healthy
 * while another product sits still for days. ADR 0011 Phase 7 removes the
 * timestamps that would let a user notice, and says plainly that a
 * silently-failing store is the most dangerous outcome in the document.
 *
 * **What this catches, and what it does NOT.** It measures WRITE RECENCY —
 * how long since a document for this product was last written. It therefore
 * catches a refresher that has stopped writing, which is the failure a
 * per-collection heartbeat hides behind other products' writes.
 *
 * It does NOT catch a refresher that keeps writing STALE CONTENT on time, and
 * an earlier version of this comment wrongly claimed it would have caught the
 * 2026-08-29 GEOGLOWS incident. It would not have. In that incident the 01:30
 * job ran daily, fetched, received a `forecast_date` one day newer than the
 * stored one, and wrote — so `fetchedAt` was never more than ~24 h old against
 * a 48 h cap, and this check would have reported healthy exactly as the old
 * one did. The store served yesterday's water while writing punctually.
 *
 * Catching that needs RUN CURRENCY, not write recency: comparing each stored
 * document's `runId` against the run upstream currently advertises. The
 * ingredients are already here — `checkStoreHealth` reads the probe, and every
 * stored document carries a `runId` that `sampleStoredWindows` simply does not
 * project. Recorded as the next step rather than implied to be done.
 *
 * **The threshold is `MAX_HOLD_MS`, deliberately reused rather than a second
 * number.** It already answers exactly the right question — how long upstream
 * can plausibly go quiet before silence stops meaning "nothing changed" — and
 * a separate constant here would drift from the window logic it must agree
 * with.
 *
 * That reuse does NOT, by itself, satisfy Phase 7 guard 4. The client never
 * sees this constant: it decides staleness from a document's `validUntil`,
 * which `storeValidUntil` computes from publish alignment, not from this cap.
 * An earlier comment here claimed the two sides shared one number; they do
 * not.
 *
 * A product with NO documents is skipped rather than reported down: nobody has
 * favourited a river that needs it, so there is nothing to be stale. The
 * newest document per product is the one judged — a single old document among
 * fresh ones is a per-reach fetch failure, which the run already records and
 * retries, not a stalled product.
 *
 * Pure, so a stalled product can be tested without freezing a real store.
 *
 * @param {readonly StoredWindowSample[]} samples - Every stored document.
 * @param {Date} now - Reference instant.
 * @return {ProductFreshness[]} One entry per product present, stalest first.
 */
export function assessProductFreshness(
  samples: readonly StoredWindowSample[],
  now: Date
): ProductFreshness[] {
  const newest = new Map<ForecastProductId, number>();

  for (const s of samples) {
    const fetchedAt = Date.parse(s.fetchedAt);
    if (Number.isNaN(fetchedAt)) continue;
    const seen = newest.get(s.product);
    if (seen === undefined || fetchedAt > seen) {
      newest.set(s.product, fetchedAt);
    }
  }

  const out: ProductFreshness[] = [];
  for (const [product, fetchedAt] of newest) {
    const ageMs = now.getTime() - fetchedAt;
    const capMs = maxHoldMs(product);
    out.push({product, ageMs, capMs, stale: ageMs > capMs});
  }

  out.sort((a, b) => (b.ageMs - b.capMs) - (a.ageMs - a.capMs));
  return out;
}

/** One product's run currency, as the health check sees it. */
export interface ProductRunCurrency {
  product: ForecastProductId;
  /** Age of the NEWEST run held for this product. */
  runAgeMs: number;
  capMs: number;
  stale: boolean;
}

/**
 * Assess how old the WATER is, as distinct from how recently we wrote.
 *
 * `assessProductFreshness` above catches a refresher that stopped. This
 * catches the failure it structurally cannot see: a refresher that keeps
 * writing, on schedule, carrying yesterday's run. That is what GEOGLOWS did
 * every day until 2026-08-29, and why a device log rather than the monitoring
 * found it.
 *
 * The newest RUN across the product's documents is judged, for the same reason
 * the newest fetch is: one reach lagging is a per-reach failure the run
 * already records and retries, not a stalled product.
 *
 * Products with no `MAX_RUN_AGE_MS` entry are skipped rather than defaulted —
 * the near-static products carry no run identity at all, and inheriting
 * somebody else's cadence is exactly how the hold cap called a healthy store
 * down within a minute of reaching production.
 *
 * Pure, so a store full of yesterday's water can be tested without waiting a
 * day for one.
 *
 * @param {readonly StoredWindowSample[]} samples - Every stored document.
 * @param {Date} now - Reference instant.
 * @return {ProductRunCurrency[]} One entry per judged product, stalest first.
 */
export function assessRunCurrency(
  samples: readonly StoredWindowSample[],
  now: Date
): ProductRunCurrency[] {
  const newestRun = new Map<ForecastProductId, number>();

  for (const s of samples) {
    if (!s.runId) continue;
    const runAt = Date.parse(s.runId);
    if (Number.isNaN(runAt)) continue;
    const seen = newestRun.get(s.product);
    if (seen === undefined || runAt > seen) newestRun.set(s.product, runAt);
  }

  const out: ProductRunCurrency[] = [];
  for (const [product, runAt] of newestRun) {
    const capMs = maxRunAgeMs(product);
    if (capMs === null) continue;
    const runAgeMs = now.getTime() - runAt;
    out.push({product, runAgeMs, capMs, stale: runAgeMs > capMs});
  }

  out.sort((a, b) => (b.runAgeMs - b.capMs) - (a.runAgeMs - a.capMs));
  return out;
}

export function assessStoreHealth(
  lastSuccessfulWrite: Date | null,
  lastProbeSample: Date | null,
  now: Date,
  samples: readonly StoredWindowSample[] = []
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

  const products = assessProductFreshness(samples, now);
  for (const p of products) {
    if (!p.stale) continue;
    problems.push(
      `${p.product} has not advanced for ` +
      `${Math.round(p.ageMs / 3600_000)}h ` +
      `(cap ${Math.round(p.capMs / 3600_000)}h)`
    );
  }

  // How old the WATER is, which write recency above cannot see.
  const runs = assessRunCurrency(samples, now);
  for (const r of runs) {
    if (!r.stale) continue;
    problems.push(
      `${r.product} is serving a run ` +
      `${Math.round(r.runAgeMs / 3600_000)}h old ` +
      `(cap ${Math.round(r.capMs / 3600_000)}h)`
    );
  }

  let status: HealthStatus = "healthy";
  if (problems.length === 1) status = "degraded";
  if (problems.length > 1) status = "down";
  if (lastWriteAgeMs === null && probeAgeMs === null) status = "down";

  return {status, problems, lastWriteAgeMs, probeAgeMs, products, runs};
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
