// test/models/1_domain/features/forecast/geoglows_forecast_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';

GeoglowsForecastPoint _pt(DateTime t, double m) =>
    GeoglowsForecastPoint(validTime: t, median: m, lower: m, upper: m);

void main() {
  group('GeoglowsForecast.currentMedian', () {
    test('returns null when there are no points', () {
      final f = GeoglowsForecast(
        riverId: '1',
        unit: 'm³/s',
        generatedAt: DateTime.now().toUtc(),
        points: const [],
      );
      expect(f.currentMedian, isNull);
    });

    test('picks the step closest to now, not the first step', () {
      final now = DateTime.now().toUtc();
      // Series starts 12h in the past (model init) and runs forward — the first
      // point is stale; the point nearest to now is the correct "current" value.
      final f = GeoglowsForecast(
        riverId: '1',
        unit: 'm³/s',
        generatedAt: now,
        points: [
          _pt(now.subtract(const Duration(hours: 12)), 100), // first, stale
          _pt(now.subtract(const Duration(hours: 1)), 200), // closest
          _pt(now.add(const Duration(hours: 10)), 300),
        ],
      );
      expect(f.currentMedian, 200);
    });

    test('handles a future-only series (first point is closest)', () {
      final now = DateTime.now().toUtc();
      final f = GeoglowsForecast(
        riverId: '1',
        unit: 'm³/s',
        generatedAt: now,
        points: [
          _pt(now.add(const Duration(hours: 2)), 50),
          _pt(now.add(const Duration(hours: 26)), 80),
        ],
      );
      expect(f.currentMedian, 50);
    });
  });
}
