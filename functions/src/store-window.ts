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
import {storeValidUntil} from "./store-document.js";

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
  analysisAssimilation: 6 * 3600_000,
  shortRange: 6 * 3600_000,
  mediumRange: 18 * 3600_000,
  longRange: 36 * 3600_000,
  geoglowsForecast: 48 * 3600_000,
};

/** Default cap for a product not named above. Deliberately short. */
export const DEFAULT_MAX_HOLD_MS = 6 * 3600_000;

/** One stored document, reduced to what the window decision needs. */
export interface StoredWindowSample {
  documentId: string;
  source: ForecastSourceId;
  product: ForecastProductId;
  /** ISO instant the value was fetched from upstream. */
  fetchedAt: string;
  /** ISO instant the document currently expires at. */
  validUntil: string;
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
  /** Documents whose window could not be read as dates. */
  malformed: string[];
}

/**
 * How long a product may be held without upstream advancing.
 *
 * @param {ForecastProductId} product - The product.
 * @return {number} Cap in milliseconds.
 */
export function maxHoldMs(product: ForecastProductId): number {
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
  samples: readonly StoredWindowSample[],
  now: Date
): WindowPlan {
  const plan: WindowPlan = {
    extend: [], abandoned: [], covered: 0, malformed: [],
  };

  for (const s of samples) {
    const fetchedAt = Date.parse(s.fetchedAt);
    const currentUntil = Date.parse(s.validUntil);
    if (Number.isNaN(fetchedAt) || Number.isNaN(currentUntil)) {
      // Never guess a window. A document whose dates cannot be read is left
      // exactly as it is, and named so it can be found.
      plan.malformed.push(s.documentId);
      continue;
    }

    if (now.getTime() - fetchedAt > maxHoldMs(s.product)) {
      // Upstream has been quiet longer than "nothing changed" can explain.
      // Let it expire and let the device tell the truth by fetching live.
      plan.abandoned.push(s.documentId);
      continue;
    }

    const target = storeValidUntil(s.source, s.product, now).getTime();
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
