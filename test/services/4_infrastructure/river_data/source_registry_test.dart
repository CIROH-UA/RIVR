// test/services/4_infrastructure/river_data/source_registry_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';

class _StubSource implements IRiverDataSource {
  _StubSource(this.source);
  @override
  final ForecastSource source;
  @override
  Set<ForecastProduct> get supportedProducts => const {};
  @override
  DateTime validUntil(ForecastProduct product, DateTime now) => now;
  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async =>
      const SourceFetchResult(payload: {}, unit: 'CMS');
}

void main() {
  group('SourceRegistry', () {
    final nwm = _StubSource(ForecastSource.nwm);
    final geoglows = _StubSource(ForecastSource.geoglows);
    final registry = SourceRegistry([nwm, geoglows]);

    test('resolves a source by ForecastSource', () {
      expect(registry.forSource(ForecastSource.nwm), same(nwm));
      expect(registry.forSource(ForecastSource.geoglows), same(geoglows));
    });

    test('resolves a source by RiverDataKey', () {
      const key = RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '1',
        product: ForecastProduct.geoglowsForecast,
      );
      expect(registry.forKey(key), same(geoglows));
    });

    test('has() reports registration', () {
      expect(registry.has(ForecastSource.nwm), isTrue);
    });

    test('throws for an unregistered source', () {
      final partial = SourceRegistry([nwm]);
      expect(
        () => partial.forSource(ForecastSource.geoglows),
        throwsStateError,
      );
    });

    test('exposes all registered sources', () {
      expect(registry.all, containsAll([nwm, geoglows]));
    });
  });
}
