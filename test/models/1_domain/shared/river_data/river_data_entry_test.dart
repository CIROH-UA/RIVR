// test/models/1_domain/shared/river_data/river_data_entry_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';

void main() {
  group('RiverDataEntry', () {
    const key = RiverDataKey(
      source: ForecastSource.geoglows,
      reachId: '210230337',
      product: ForecastProduct.geoglowsForecast,
    );
    final entry = RiverDataEntry(
      key: key,
      window: FreshnessWindow(
        fetchedAt: DateTime.utc(2026, 7, 10, 0, 30),
        validUntil: DateTime.utc(2026, 7, 11, 0, 0),
      ),
      payload: const {
        'flow_median': [1.2, 3.4],
        'unit': 'CMS',
      },
    );

    test('round-trips through JSON preserving key, window, and payload', () {
      final restored = RiverDataEntry.fromJson(entry.toJson());
      expect(restored.key, key);
      expect(restored.window.fetchedAt, entry.window.fetchedAt);
      expect(restored.window.validUntil, entry.window.validUntil);
      expect(restored.payload['unit'], 'CMS');
      expect(restored.payload['flow_median'], [1.2, 3.4]);
    });

    test('isFreshAt delegates to the window', () {
      expect(entry.isFreshAt(DateTime.utc(2026, 7, 10, 12, 0)), isTrue);
      expect(entry.isFreshAt(DateTime.utc(2026, 7, 11, 1, 0)), isFalse);
    });
  });
}
