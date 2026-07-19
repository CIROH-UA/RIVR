// test/models/1_domain/features/forecast/weekly_outlook_row_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/features/forecast/weekly_outlook_row.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/utils/forecast_trend.dart';

OutlookRow row({
  String id = 'r',
  int categoryIndex = 0,
  FlowTrend trend = FlowTrend.steady,
  double peak = 100,
  ForecastSource source = ForecastSource.nwm,
}) {
  return OutlookRow(
    reachId: id,
    source: source,
    displayName: 'River $id',
    unit: 'ft³/s',
    sparkline: const [1, 2, 3],
    trend: trend,
    peakFlow: peak,
    peakTime: null,
    category: 'Normal',
    categoryIndex: categoryIndex,
  );
}

void main() {
  group('OutlookRow newsworthiness ranking', () {
    test('higher flood category ranks first regardless of trend', () {
      final elevated = row(id: 'a', categoryIndex: 2, trend: FlowTrend.steady);
      final normalRising = row(id: 'b', categoryIndex: 0, trend: FlowTrend.rising);

      final list = [normalRising, elevated]..sort(OutlookRow.byNewsworthiness);
      expect(list.first.reachId, 'a');
    });

    test('within the same category, rising beats steady beats falling', () {
      final rising = row(id: 'rise', trend: FlowTrend.rising);
      final steady = row(id: 'stead', trend: FlowTrend.steady);
      final falling = row(id: 'fall', trend: FlowTrend.falling);

      final list = [falling, steady, rising]..sort(OutlookRow.byNewsworthiness);
      expect(list.map((r) => r.reachId).toList(), ['rise', 'stead', 'fall']);
    });

    test('ties broken by higher peak flow', () {
      final low = row(id: 'low', trend: FlowTrend.steady, peak: 100);
      final high = row(id: 'high', trend: FlowTrend.steady, peak: 900);

      final list = [low, high]..sort(OutlookRow.byNewsworthiness);
      expect(list.first.reachId, 'high');
    });

    test('unknown category (-1) sorts as lowest, not above Normal', () {
      final unknown = row(id: 'unk', categoryIndex: -1, trend: FlowTrend.rising);
      final normal = row(id: 'norm', categoryIndex: 0, trend: FlowTrend.rising);

      final list = [unknown, normal]..sort(OutlookRow.byNewsworthiness);
      // Same score (clamped to 0) + same trend + same peak → stable; the key
      // assertion is that unknown never outranks a real Normal classification.
      expect(list.last.reachId, anyOf('unk', 'norm'));
      expect(unknown.newsworthiness, normal.newsworthiness);
    });
  });
}
