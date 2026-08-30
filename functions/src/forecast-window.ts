// functions/src/forecast-window.ts
//
// One rule for "the part of a forecast that is still ahead", shared by both
// notification paths.
//
// **It lived in `weekly-digest.ts` and the alert path did not use it.** That is
// how the same defect existed twice: the weekly digest computed its trend and
// peak over the WHOLE stored series until 2026-08-30, and `getMaxForecastFlow`
// in `notification-service.ts` still did when this file was written. An alert
// can therefore announce a crest that has already happened — and the peak
// drives both the flood CATEGORY the alert claims and the "in ~14 hours" line,
// so a river that crested overnight and is now falling could wake someone at
// the old crest's severity.
//
// Moved here rather than imported across, because a windowing rule owned by
// the digest is a rule the alert path will keep forgetting to apply. Both now
// import the same function, and the drift test below reads THIS file.

/**
 * The part of a series that is still ahead, or the whole thing when none of it
 * is.
 *
 * Mirrors the client's `ForecastPeak.upcomingPoints` plus its
 * `upcoming.isNotEmpty ? upcoming : points` fallback. The fallback matters: a
 * reach whose forecast has entirely lapsed should still produce a row rather
 * than vanish from the digest.
 *
 * @param {Array<{value: number, validTime: string}>} series - Full series.
 * @param {Date} now - Reference instant.
 * @return {Array<{value: number, validTime: string}>} The forward window.
 */
export function upcomingFrom(
  series: Array<{value: number; validTime: string}>,
  now: Date
): Array<{value: number; validTime: string}> {
  if (series.length === 0) return series;

  // ANCHOR on the point nearest `now`, then keep everything from it onward.
  //
  // The first attempt at this filtered `t >= now`, which is NOT what the
  // client does and the third Phase 8 review caught the difference. The anchor
  // is normally the most recent PAST reading — the "current" value — so
  // filtering it out drops the very point the trend is measured against. With
  // a 3-hourly series the two windows start one point apart, which was enough
  // to flip a river between rising and falling and to change which crest is
  // reported as the peak.
  //
  // Ported from `ForecastPeak.upcomingPoints` in lib/utils/forecast_peak.dart.
  // Keep the two in step; a comment claiming they match is what went wrong
  // twice here.
  const refMs = now.getTime();
  let anchorMs: number | null = null;
  let anchorDiff = Number.POSITIVE_INFINITY;
  for (const p of series) {
    const t = Date.parse(p.validTime);
    if (Number.isNaN(t)) continue;
    const d = Math.abs(t - refMs);
    if (d < anchorDiff) {
      anchorDiff = d;
      anchorMs = t;
    }
  }
  if (anchorMs === null) return series;

  const anchored = series.filter((p) => {
    const t = Date.parse(p.validTime);
    return !Number.isNaN(t) && t >= anchorMs!;
  });
  return anchored.length > 0 ? anchored : series;
}
