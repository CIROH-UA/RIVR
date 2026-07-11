// test/models/1_domain/shared/forecast_source_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';

void main() {
  group('ForecastSource.fromLayerIds', () {
    test('returns geoglows when a geoglows-prefixed layer is matched', () {
      expect(
        ForecastSource.fromLayerIds(['geoglows-order-5-plus']),
        ForecastSource.geoglows,
      );
    });

    test('returns nwm for NWM stream layers', () {
      expect(
        ForecastSource.fromLayerIds(['streams2-order-3-4']),
        ForecastSource.nwm,
      );
    });

    test('defaults to nwm for empty / null layer ids', () {
      expect(ForecastSource.fromLayerIds([]), ForecastSource.nwm);
      expect(ForecastSource.fromLayerIds([null]), ForecastSource.nwm);
    });

    test('prefers geoglows when both kinds are present', () {
      expect(
        ForecastSource.fromLayerIds(['streams2-order-1-2', 'geoglows-order-1-2']),
        ForecastSource.geoglows,
      );
    });
  });

  group('ForecastSource id round-trip', () {
    test('fromId(name) is identity; unknown -> nwm', () {
      for (final s in ForecastSource.values) {
        expect(ForecastSource.fromId(s.id), s);
      }
      expect(ForecastSource.fromId('bogus'), ForecastSource.nwm);
      expect(ForecastSource.fromId(null), ForecastSource.nwm);
    });
  });

  group('SelectedReach.fromVectorTile', () {
    final props = {'station_id': 210166987, 'streamOrder': 2};

    test('defaults to nwm source', () {
      final r = SelectedReach.fromVectorTile(
        properties: props,
        latitude: 45.69,
        longitude: 4.81,
      );
      expect(r.reachId, '210166987');
      expect(r.source, ForecastSource.nwm);
    });

    test('carries an explicit geoglows source through copies', () {
      final r = SelectedReach.fromVectorTile(
        properties: props,
        latitude: 45.69,
        longitude: 4.81,
        source: ForecastSource.geoglows,
      );
      expect(r.source, ForecastSource.geoglows);
      // source survives the async-enrichment copies
      expect(r.withRiverName('Rhône').source, ForecastSource.geoglows);
      expect(
        r.withLocation(city: 'Lyon', state: 'France').source,
        ForecastSource.geoglows,
      );
    });
  });
}
