// functions/src/store-window.ts
//
// ADR 0011 Phase 5: keeping a stored document's window honest between runs.
//
// The problem this exists for, measured on a device 2026-08-28. A stored
// document's `validUntil` used to answer only "when could upstream next
// publish?" — but a stored value is not replaced when upstream publishes, it
// is replaced when OUR refresher next writes one. Hourly documents were
// written at :20 and expired at :05, so for 15 minutes of every hour every
// document in the store was marked stale while still being the newest value in
// existence, and every device fell through to the live path. A clean-install
// phone tested inside that gap made 78 NOAA calls; the same phone tested
// outside it made zero.
//
// `storeValidUntil` fixes that at WRITE time. This module fixes the other half:
// a product whose upstream run has not advanced is never rewritten, so its
// window keeps ending regardless. Long range is the extreme case — NOAA served
// an empty `longRange` section for hours on 2026-08-28, the 12Z run did not
// land until 21:20 UTC, and in between all 30 documents sat expired holding
// the only long-range data that existed anywhere.
//
// So when a run checks and finds nothing newer, that is *information*: it means
// the stored value is still current. We record it by extending the window
// rather than letting the document rot.
//
// **This is not "keep it alive forever".** Each product has a cap on how long
// it may be held without upstream confirming a new run. Past that cap the
// document is left to expire, the device falls back to the live path, and the
// staleness becomes honest again. A store that quietly served a three-day-old
// forecast because upstream went dark would be worse than one that expired.

import {
  ForecastProductId,
  ForecastSourceId,
} from "./store-keys.js";
import {isIslandReach, storeValidUntil} from "./store-document.js";

/**
 * How long a value may be held on re-verification alone, per product.
 *
 * The unit is "how long upstream can plausibly go without publishing before
 * silence stops meaning 'nothing changed' and starts meaning 'something is
 * broken'". Hourly products get six missed cycles. Long range gets 36 hours
 * because its observed publish lag is ~9 hours on top of a 6-hour nominal
 * cycle (12Z run landed 21:20Z on 2026-08-28), so a shorter cap would expire
 * documents that are simply waiting, which is the bug this file exists to fix.
 */
export const MAX_HOLD_MS: Readonly<Record<string, number>> = {
  currentFlow: 6 * 3600_000,
  shortRange: 6 * 3600_000,
  mediumRange: 18 * 3600_000,
  longRange: 36 * 3600_000,
  geoglowsForecast: 48 * 3600_000,

  // The near-static products are NOT on any refresh cycle. They hold a 30-day
  // window (STATIC_PRODUCT_MS) and `storeStaticDaily` rewrites one only when it
  // is missing or within 7 days of expiring, so a perfectly healthy document
  // sits untouched for about 23 days. Judging them by the 6-hour default said
  // the store was DOWN 17 hours after a normal write — caught in production
  // 2026-08-29, within a minute of the per-product health check going live.
  //
  // 32 days is the 30-day window plus room for the daily pass to come round.
  // Past that a document really has stopped being maintained.
  reachMetadata: 32 * 24 * 3600_000,
  returnPeriods: 32 * 24 * 3600_000,
};

/** Default cap for a product not named above. Deliberately short. */
export const DEFAULT_MAX_HOLD_MS = 6 * 3600_000;

/**
 * Hold caps that REPLACE `MAX_HOLD_MS` for Hawaii and Puerto Rico reaches.
 *
 * Mirrors `islandMaxHold` in
 * `lib/services/4_infrastructure/river_data/hold_policy.dart` and is pinned
 * against it by `hold-policy-drift.test.ts`.
 *
 * A second table rather than a bigger shared number: the cap encodes how long
 * silence can mean "nothing changed", which follows the publish cadence.
 * Island short range publishes every 6 hours (Puerto Rico) or 12 (Hawaii)
 * against CONUS's hourly, measured 2026-08-30 from NOAA's production listing.
 * Raising the shared cap to 24 hours would let a genuinely stuck CONUS
 * document look healthy for a day.
 *
 * 24 hours is two missed Hawaii cycles — the same shape as long range's
 * 6-hour cycle and 36-hour cap. Below it a healthy Hawaii document expires
 * BETWEEN runs, and every device holding that favourite drops to the live path
 * for half of every cycle.
 */
export const ISLAND_MAX_HOLD_MS: Readonly<Record<string, number>> = {
  shortRange: 24 * 3600_000,
  // `currentFlow` is a misnomer: `store-upstream` maps it to the
  // `"short_range"` series, so it publishes on short range's cadence and needs
  // short range's cap. Omitting it left island current-flow documents on the
  // 6-hour CONUS cap while carrying 12-hourly Hawaii data.
  currentFlow: 24 * 3600_000,
};

/**
 * Run-age caps that REPLACE `MAX_RUN_AGE_MS` for island reaches.
 *
 * The CONUS cap of 16 hours would have false-alarmed on the day this was
 * written: NWPS reach 800000010 (Oahu) reported its short-range run as 00:00Z
 * at 15:16Z on 2026-08-30 — 15.3 hours old and still the newest in existence.
 *
 * 28 hours is one full Hawaii cycle plus the observed publication lag plus
 * margin, and still catches a stuck run: two missed cycles is 36 hours.
 */
export const ISLAND_MAX_RUN_AGE_MS: Readonly<Record<string, number>> = {
  shortRange: 28 * 3600_000,
  // Same reason as ISLAND_MAX_HOLD_MS: this product carries short-range water.
  currentFlow: 28 * 3600_000,
};

/** One stored document, reduced to what the window decision needs. */
export interface StoredWindowSample {
  documentId: string;
  source: ForecastSourceId;
  /**
   * Which reach this document is for.
   *
   * Carried explicitly rather than parsed back out of `documentId`. The id
   * format is a cross-language contract and re-deriving a field from it here
   * would make this file a second place that has to know it — the kind of
   * quiet duplication that survives a rename until something breaks in
   * production. Needed since Phase 9, because a Hawaii or Puerto Rico
   * short-range document expires on a different cycle from a CONUS one.
   */
  reachId: string;
  product: ForecastProductId;
  /** ISO instant the value was fetched from upstream. */
  fetchedAt: string;
  /** ISO instant the document currently expires at. */
  validUntil: string;
  /**
   * The upstream run this value came from, when it has one.
   *
   * Absent for the near-static products, which carry no run identity — that
   * is precisely why they are not on the hourly trigger cycle.
   */
  runId?: string;
}

/**
 * How old the RUN ITSELF may be, per product.
 *
 * **Not the same question as [MAX_HOLD_MS], and the distinction is the whole
 * point.** `MAX_HOLD_MS` measures how long ago we last WROTE. This measures
 * how old the water is that we wrote. A refresher that runs perfectly on
 * schedule, fetching and storing punctually every single time, can hold
 * yesterday's forecast forever and look flawless by the first measure.
 *
 * That is not hypothetical. It is what GEOGLOWS did every day until
 * 2026-08-29: the 01:30 job fetched, received a `forecast_date` one day newer
 * than the stored one, wrote it, and moved on. `fetchedAt` was never more than
 * a few hours old. The store served yesterday's water while writing on time,
 * and it took a device log to notice.
 *
 * Every `runId` is an ISO instant — NWM uses the run's `referenceTime`, and
 * GEOGLOWS's date-only `forecast_date` is widened to that day's 00Z by
 * `normaliseForecastDate` — so run age is comparable across both sources.
 *
 * The numbers are publish cadence plus the observed lag, not guesses:
 *
 * **The first version of these numbers was wrong in two places, and both were
 * caught before deploying — by measurement, not by reasoning.**
 *
 * - **16 h** for the hourly NWM products. The first attempt used 8 h on the
 *   argument that "a five-hour NOAA stall is recorded here as normal". That
 *   forgot that run age = publish lag + stall: NOAA's `referenceTime` is
 *   already ~3 h behind the wall clock on an ordinary day. Replaying 163
 *   samples from `publish_cadence_log`, an 8 h cap would have fired on
 *   **29 of them (17.8%)** for `currentFlow` and 7 (4.3%) for
 *   `shortRange`, with a maximum observed age of 11.0 h. 16 h clears the
 *   worst observed sample, the documented five-hour stall on top of the
 *   baseline lag, and one missed refresh interval.
 * - **24 h / 36 h** for medium and long range. Unchanged: 0 of 153 and 0 of
 *   155 samples would have fired, with maxima of 13.0 h and 21.0 h. The 12Z
 *   run landing at 21:20Z (2026-08-28) is a ~15 h worst case, inside both.
 * - **42 h** for GEOGLOWS, not 36 h. The run is stamped 00Z and published
 *   10:15-10:30 UTC, but what matters is when WE fetch it, and
 *   `storeGeoglowsDaily` runs at 11:30 UTC with no retry — so a stored run
 *   legitimately reaches **35.5 h** just before replacement, leaving 36 h
 *   about twenty-five minutes of margin. MEASURED, not derived: the run check
 *   at 2026-08-29T11:30:34Z logged `held: 2026-08-28T00:00:00Z` against
 *   `upstream: 2026-08-29T00:00:00Z` — a 35.5 h old run still in the store,
 *   replaced seconds later. Any publication later than ~11:30
 *   would have returned 503 continuously for the next 23 hours, and "the
 *   schedule is not trusted" is exactly why the probe-and-fan-out design
 *   exists. 42 h keeps the incident caught: the old 01:30 schedule let a run
 *   reach 49.5 h before replacement.
 */
export const MAX_RUN_AGE_MS: Readonly<Record<string, number>> = {
  currentFlow: 16 * 3600_000,
  shortRange: 16 * 3600_000,
  mediumRange: 24 * 3600_000,
  longRange: 36 * 3600_000,
  geoglowsForecast: 42 * 3600_000,
};

/**
 * How old [product]'s run may be, or null when it is not judged.
 *
 * Returns null rather than a default on purpose. An unknown product here must
 * NOT inherit someone else's cadence: the near-static products have no run at
 * all, and a wrong default is how the hold cap reported a healthy store as
 * down within a minute of reaching production.
 *
 * @param {ForecastProductId} product - The product.
 * @return {number | null} Cap in milliseconds, or null if not applicable.
 */
export function maxRunAgeMs(
  product: ForecastProductId,
  reachId: string
): number | null {
  if (isIslandReach(reachId)) {
    const island = ISLAND_MAX_RUN_AGE_MS[product];
    if (island !== undefined) return island;
  }
  return MAX_RUN_AGE_MS[product] ?? null;
}

/** A window to re-stamp. */
export interface WindowExtension {
  documentId: string;
  validUntil: string;
}

/** What one planning pass decided. */
export interface WindowPlan {
  /** Documents to re-stamp, with their new expiry. */
  extend: WindowExtension[];
  /**
   * Documents deliberately left to expire because the value is older than its
   * product's cap. Reported, not silent — this is the store admitting upstream
   * has gone quiet for longer than "nothing changed" can explain.
   */
  abandoned: string[];
  /** Documents already covered past the next refresh; nothing to do. */
  covered: number;
  /**
   * Documents outside the work list — reaches nobody favourites any more,
   * still inside the GC's seven-day grace.
   *
   * Counted SEPARATELY from [abandoned], and that separation is the whole
   * point. No run will ever rewrite an orphan, so every hour it sits further
   * past its hold cap; folding it into `abandoned` reported "upstream has
   * gone quiet" at ERROR, hourly, for a store that was working perfectly.
   * Measured 2026-08-30: 83 store errors in seven days, every hold-cap one of
   * them four unfavourited reaches.
   */
  orphaned: number;
  /** Documents whose window could not be read as dates. */
  malformed: string[];
}

/**
 * How long a product may be held without upstream advancing.
 *
 * @param {ForecastProductId} product - The product.
 * @return {number} Cap in milliseconds.
 */
export function maxHoldMs(
  product: ForecastProductId,
  reachId: string
): number {
  if (isIslandReach(reachId)) {
    const island = ISLAND_MAX_HOLD_MS[product];
    if (island !== undefined) return island;
  }
  return MAX_HOLD_MS[product] ?? DEFAULT_MAX_HOLD_MS;
}

/**
 * Decide which stored documents should have their windows extended.
 *
 * Pure. The caller supplies the samples and applies the result, so the
 * decision is testable without Firestore.
 *
 * @param {readonly StoredWindowSample[]} samples - Documents to consider.
 * @param {Date} now - Reference instant.
 * @return {WindowPlan} What to extend, what to abandon, what needs nothing.
 */
export function planWindowExtensions(
  liveDocumentIds: ReadonlySet<string>,
  samples: readonly StoredWindowSample[],
  now: Date
): WindowPlan {
  const plan: WindowPlan = {
    extend: [], abandoned: [], covered: 0, orphaned: 0, malformed: [],
  };

  for (const s of samples) {
    // Orphans first, before any judgement about staleness. A document for a
    // reach nobody follows is not stale — it is unmaintained on purpose, and
    // no run will ever rewrite it. Judging it by a hold cap says "upstream
    // has gone quiet" about a store that is working exactly as designed.
    if (!liveDocumentIds.has(s.documentId)) {
      plan.orphaned++;
      continue;
    }

    const fetchedAt = Date.parse(s.fetchedAt);
    const currentUntil = Date.parse(s.validUntil);
    if (Number.isNaN(fetchedAt) || Number.isNaN(currentUntil)) {
      // Never guess a window. A document whose dates cannot be read is left
      // exactly as it is, and named so it can be found.
      plan.malformed.push(s.documentId);
      continue;
    }

    if (now.getTime() - fetchedAt > maxHoldMs(s.product, s.reachId)) {
      // Upstream has been quiet longer than "nothing changed" can explain.
      // Let it expire and let the device tell the truth by fetching live.
      plan.abandoned.push(s.documentId);
      continue;
    }

    // Never promise past the hold cap. The extension used to stamp the full
    // refresh floor, so the LAST extension before a document was abandoned
    // reached one whole refresh interval beyond the cap — and the client,
    // which stops vouching exactly at the cap, spent that interval showing a
    // warning over the newest data that exists anywhere. For short range that
    // is ~70 minutes; for GEOGLOWS, whose refresh interval is a day, it is
    // ~24 hours. The warning then cleared by re-fetching the identical bytes
    // through the live path.
    //
    // Clamping makes the two sides agree to the instant, which is what
    // hold_policy.dart and ADR decision 22 both claim.
    const capEnd = fetchedAt + maxHoldMs(s.product, s.reachId);
    const target = Math.min(
      storeValidUntil(s.source, s.product, now, s.reachId).getTime(), capEnd);
    if (target <= currentUntil) {
      plan.covered++;
      continue;
    }
    plan.extend.push({
      documentId: s.documentId,
      validUntil: new Date(target).toISOString(),
    });
  }

  return plan;
}
