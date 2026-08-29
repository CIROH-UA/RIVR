// functions/src/flow-classification.ts
//
// ADR 0011 Phase 6 guard 3, and ADR 0002's canonical ladder crossing the
// language boundary.
//
// **The mirror of lib/models/1_domain/shared/flow_classification.dart.** That
// file's own header says every surface must classify through it and that
// reimplementing the thresholds inline is how the app once showed "Action" on
// the gauge and "Elevated" on the hourly card for the same flow. The server is
// simply another surface: an alert that says one thing while the card the user
// then opens says another is the same defect wearing a different hat, and it is
// worse, because the alert is what wakes them up.
//
// Phase 6 guard 3 states it directly: "The category a user sees and the one the
// alert fired on come from the same code. Reading the same document is not
// sufficient — identical inputs through different implementations can still
// disagree."
//
// Two implementations in two languages cannot literally be the same code, so
// the next best thing is enforced here: the ladder is defined once per
// language, and a test reads the Dart source off disk and fails the build if
// the names, the recurrence intervals, or the comparison boundaries drift
// apart. That is the same technique store-document.ts uses to pin the
// freshness skews.
//
// **What the alert did before this file existed:** it never computed a category
// at all. It reported the raw recurrence interval it had exceeded — "2-year",
// "100-year" — and a raw streamflow number, neither of which appears anywhere
// in the app's vocabulary. A push notification reading "Forecast: 147362 CFS
// (exceeds 25-year flood threshold)" tells a reader nothing they can act on.

/**
 * Ordered flood categories, low to high. Index doubles as the gauge zone index.
 *
 * Mirrors `kFloodCategories`. Order and spelling are both load-bearing: the
 * index is what the app's palette (ADR 0007) is aligned to.
 */
export const FLOOD_CATEGORIES = [
  "Normal",
  "Action",
  "Moderate",
  "Major",
  "Extreme",
] as const;

export type FloodCategory = typeof FLOOD_CATEGORIES[number] | "Unknown";

/**
 * The recurrence intervals the ladder is built from, ascending.
 *
 * NOT every threshold the upstream API returns — it also publishes 50-year and
 * 100-year values, and the alert path used to compare against all of them. That
 * is why an alert could announce a "100-year" event for a flow the app calls
 * "Extreme": not a disagreement about severity, but two different vocabularies
 * for the same water. Everything at or above the 25-year level is Extreme here,
 * exactly as it is on the card.
 */
export const LADDER_YEARS = [2, 5, 10, 25] as const;

/**
 * Category index 0..4 for [flow] against return-period [thresholds], both in
 * the SAME unit; -1 when it cannot be determined.
 *
 * The comparisons are `<`, matching Dart exactly. A flow equal to a threshold
 * falls in the HIGHER category — flow == t2 is Action, not Normal. Boundary
 * direction is the easiest thing to get silently wrong between two
 * implementations, so it is pinned by test.
 *
 * @param {number | null} flow - Flow, in the same unit as the thresholds.
 * @param {Record<number, number> | null} thresholds - Return-period thresholds
 *   keyed by recurrence year.
 * @return {number} Index 0..4, or -1 when undeterminable.
 */
export function indexFor(
  flow: number | null | undefined,
  thresholds: Record<number, number> | null | undefined
): number {
  if (flow === null || flow === undefined) return -1;
  if (thresholds === null || thresholds === undefined) return -1;

  const t2 = thresholds[2];
  const t5 = thresholds[5];
  const t10 = thresholds[10];
  const t25 = thresholds[25];

  // All four required, like Dart. A partial ladder cannot be ranked, and
  // guessing would put a river in a category the app would never show it in.
  if (t2 === undefined || t5 === undefined ||
      t10 === undefined || t25 === undefined) {
    return -1;
  }
  if (!Number.isFinite(t2) || !Number.isFinite(t5) ||
      !Number.isFinite(t10) || !Number.isFinite(t25)) {
    return -1;
  }
  if (!Number.isFinite(flow)) return -1;

  if (flow < t2) return 0;
  if (flow < t5) return 1;
  if (flow < t10) return 2;
  if (flow < t25) return 3;
  return 4;
}

/**
 * Category name for [flow], or "Unknown" when thresholds are unavailable.
 *
 * @param {number | null} flow - Flow, in the same unit as the thresholds.
 * @param {Record<number, number> | null} thresholds - Return-period thresholds.
 * @return {FloodCategory} The category name.
 */
export function categoryFor(
  flow: number | null | undefined,
  thresholds: Record<number, number> | null | undefined
): FloodCategory {
  const i = indexFor(flow, thresholds);
  return i < 0 ? "Unknown" : FLOOD_CATEGORIES[i];
}

/**
 * Whether a category is high enough to notify on.
 *
 * The floor is **Action**, confirmed by Jerson 2026-08-29. Alerts already fired
 * at any exceeded threshold, which is Action and above, so this names the
 * existing behaviour rather than changing it — and puts it somewhere a future
 * change has to be deliberate about.
 *
 * @param {FloodCategory} category - The category to test.
 * @return {boolean} True when an alert is warranted.
 */
export function warrantsAlert(category: FloodCategory): boolean {
  if (category === "Unknown") return false;
  return FLOOD_CATEGORIES.indexOf(category) >=
    FLOOD_CATEGORIES.indexOf("Action");
}
