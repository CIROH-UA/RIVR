// test/models/1_domain/shared/river_data/river_data_key_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';

void main() {
  const key = RiverDataKey(
    source: ForecastSource.nwm,
    reachId: '23021904',
    product: ForecastProduct.shortRange,
  );

  group('RiverDataKey', () {
    test('storageKey is stable and human-readable', () {
      expect(key.storageKey, 'nwm__23021904__shortRange');
    });

    test('value equality — same fields are equal with equal hashCodes', () {
      const same = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.shortRange,
      );
      expect(key, same);
      expect(key.hashCode, same.hashCode);
    });

    test('differs when any dimension differs', () {
      const otherSource = RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '23021904',
        product: ForecastProduct.shortRange,
      );
      const otherReach = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '99999999',
        product: ForecastProduct.shortRange,
      );
      const otherProduct = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.mediumRange,
      );
      expect(key, isNot(otherSource));
      expect(key, isNot(otherReach));
      expect(key, isNot(otherProduct));
    });

    test('same reach id under two sources does not collide', () {
      const nwm = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '740353213',
        product: ForecastProduct.shortRange,
      );
      const geoglows = RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '740353213',
        product: ForecastProduct.geoglowsForecast,
      );
      expect(nwm.storageKey, isNot(geoglows.storageKey));
      expect(nwm, isNot(geoglows));
    });

    test('usable as a Map/Set key (equal keys de-duplicate)', () {
      const duplicate = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.shortRange,
      );
      final set = <RiverDataKey>{}
        ..add(key)
        ..add(duplicate);
      expect(set.length, 1);

      final map = <RiverDataKey, int>{key: 1};
      map[duplicate] = 2;
      expect(map.length, 1);
      expect(map[key], 2);
    });
  });
}
