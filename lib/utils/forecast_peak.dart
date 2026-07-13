// lib/utils/forecast_peak.dart

/// Canonical definition of a forecast "peak" for the whole app.
///
/// A peak the user cares about is the highest flow they still have **ahead** of
/// them — the crest to prepare for — NOT one that already passed. This matters
/// because forecast series routinely include timesteps at or just before "now":
/// GEOGLOWS deterministic forecasts start at the model-init time (often earlier
/// today), and NWM analysis/assimilation points are in the past. Taking a naive
/// max over the whole series can therefore report a peak that already happened
/// (and a nonsensical "time to peak: now" when it was really yesterday).
///
/// So every peak the app surfaces — the stat card's "Peak · range" and "Time to
/// peak", the hydrograph's peak callout, and the weekly-outlook peaks — is
/// computed from the **current reading onward** via this helper.
///
/// The window is anchored on the point closest to `now` (the same point the
/// gauge shows as the current flow), not on `now` itself. That way:
///   - daily series (e.g. GEOGLOWS, one point per day) still count *today* even
///     though its timestamp is 00:00 and technically before the current instant;
///   - sub-hourly series exclude earlier-today points that are genuinely past;
///   - the peak is always >= the current flow (a receding river peaks "now").
class ForecastPeak {
  const ForecastPeak._();

  /// The points from the current reading onward — everything still ahead of the
  /// user. Points before the current reading are dropped. Returns an empty list
  /// for empty input. See the class doc for why the anchor is the closest point
  /// to `now` rather than `now` itself.
  static List<({double flow, DateTime time})> upcomingPoints(
    Iterable<({double flow, DateTime time})> points, {
    DateTime? now,
  }) {
    final list = points.toList();
    if (list.isEmpty) return list;
    final ref = now ?? DateTime.now();

    // Anchor on the point closest to now — the "current" reading.
    var anchor = list.first.time;
    var anchorDiff = anchor.difference(ref).abs();
    for (final p in list) {
      final d = p.time.difference(ref).abs();
      if (d < anchorDiff) {
        anchorDiff = d;
        anchor = p.time;
      }
    }

    return [
      for (final p in list)
        if (!p.time.isBefore(anchor)) p,
    ];
  }

  /// The highest-flow point from the current reading onward, or null for empty
  /// input. This is THE peak — use it anywhere the app shows a peak flow, peak
  /// category, or time-to-peak, so "peak" never means a crest that already
  /// passed.
  static ({double flow, DateTime time})? upcoming(
    Iterable<({double flow, DateTime time})> points, {
    DateTime? now,
  }) {
    ({double flow, DateTime time})? best;
    for (final p in upcomingPoints(points, now: now)) {
      if (best == null || p.flow > best.flow) best = p;
    }
    return best;
  }
}
