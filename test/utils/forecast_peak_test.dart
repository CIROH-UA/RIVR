// test/utils/forecast_peak_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/utils/forecast_peak.dart';

({double flow, DateTime time}) p(double flow, DateTime time) =>
    (flow: flow, time: time);

void main() {
  final now = DateTime(2026, 7, 13, 10);

  group('ForecastPeak.upcoming', () {
    test('ignores a higher crest that already passed', () {
      // Peaked yesterday (1771), receding to 1593 now, easing after.
      final pts = [
        p(1771, DateTime(2026, 7, 12, 0)), // past crest — must be ignored
        p(1593, DateTime(2026, 7, 13, 0)), // today / current reading
        p(1400, DateTime(2026, 7, 14, 0)),
        p(1200, DateTime(2026, 7, 15, 0)),
      ];
      final peak = ForecastPeak.upcoming(pts, now: now);
      expect(peak!.flow, 1593); // the current reading, not the past 1771
      expect(peak.time, DateTime(2026, 7, 13, 0));
    });

    test('finds a future crest when the river is rising', () {
      final pts = [
        p(800, DateTime(2026, 7, 13, 0)), // current
        p(1500, DateTime(2026, 7, 14, 0)),
        p(4200, DateTime(2026, 7, 15, 0)), // upcoming crest
        p(3000, DateTime(2026, 7, 16, 0)),
      ];
      final peak = ForecastPeak.upcoming(pts, now: now);
      expect(peak!.flow, 4200);
      expect(peak.time, DateTime(2026, 7, 15, 0));
    });

    test('anchors on the closest point so daily "today" still counts', () {
      // Today's point is at 00:00 (10h before now) but is the closest to now,
      // so it must be included and win for a receding series.
      final pts = [
        p(1593, DateTime(2026, 7, 13, 0)),
        p(1400, DateTime(2026, 7, 14, 0)),
      ];
      expect(ForecastPeak.upcoming(pts, now: now)!.flow, 1593);
    });

    test('returns null for empty input', () {
      expect(ForecastPeak.upcoming(const [], now: now), isNull);
    });
  });

  group('ForecastPeak.upcomingPoints', () {
    test('drops points before the current reading', () {
      final pts = [
        p(1771, DateTime(2026, 7, 12, 0)),
        p(1593, DateTime(2026, 7, 13, 0)),
        p(1400, DateTime(2026, 7, 14, 0)),
      ];
      final up = ForecastPeak.upcomingPoints(pts, now: now);
      expect(up.map((e) => e.flow).toList(), [1593, 1400]);
    });
  });
}
