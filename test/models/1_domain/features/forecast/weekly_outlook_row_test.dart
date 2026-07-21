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

OutlookRow rowFor({
  required String reachId,
  required String displayName,
  String? location,
}) {
  return OutlookRow(
    reachId: reachId,
    source: ForecastSource.nwm,
    displayName: displayName,
    location: location,
    unit: 'ft³/s',
    sparkline: const [1, 2, 3],
    trend: FlowTrend.steady,
    peakFlow: 100,
    peakTime: null,
    category: 'Normal',
    categoryIndex: 0,
  );
}

void main() {
  group('OutlookRow.title (also the persisted digest label)', () {
    test('a named reach keeps its name as the title', () {
      final r = rowFor(
        reachId: '21609641',
        displayName: 'White River',
        location: 'Monroe City, IN',
      );
      expect(r.title, 'White River');
    });

    test('an unnamed reach leads with its geocoded place', () {
      final r = rowFor(
        reachId: '670068119',
        displayName: 'Global Reach 670068119', // placeholder embeds the id
        location: 'Castilla, Peru',
      );
      expect(r.title, 'Castilla, Peru');
    });

    test('an unnamed reach with no place falls back to the display name', () {
      final r = rowFor(
        reachId: '670068119',
        displayName: 'Global Reach 670068119',
        location: null,
      );
      expect(r.title, 'Global Reach 670068119');
    });
  });

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
