// test/utils/forecast_trend_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/utils/forecast_trend.dart';

void main() {
  group('computeFlowTrend', () {
    test('monotonic increase is rising', () {
      expect(computeFlowTrend([10, 20, 30, 40, 50]), FlowTrend.rising);
    });

    test('monotonic decrease is falling', () {
      expect(computeFlowTrend([50, 40, 30, 20, 10]), FlowTrend.falling);
    });

    test('flat-ish series (within ±5%) is steady', () {
      expect(computeFlowTrend([100, 101, 99, 100, 100]), FlowTrend.steady);
    });

    test('a crest ahead reads as rising (peak-anchored, matches detail page)', () {
      // Rises to a midweek crest then recedes to the start — the crest is the
      // story, so it's Rising (not steady), consistent with "peaks in N days".
      expect(computeFlowTrend([100, 100, 400, 100, 100]), FlowTrend.rising);
    });

    test('peak just above current (>5%) is rising', () {
      // 100 -> peak 108 is +8%, above the 5% threshold.
      expect(computeFlowTrend([100, 102, 104, 106, 108]), FlowTrend.rising);
    });

    test('fewer than two points is steady', () {
      expect(computeFlowTrend([]), FlowTrend.steady);
      expect(computeFlowTrend([42]), FlowTrend.steady);
    });

    test('rising from zero baseline is rising', () {
      expect(computeFlowTrend([0, 0, 5, 10, 20]), FlowTrend.rising);
    });
  });
}
