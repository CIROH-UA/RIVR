// test/models/1_domain/shared/river_data/forecast_product_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';

void main() {
  group('ForecastProduct', () {
    test('id round-trips through fromId for every value', () {
      for (final product in ForecastProduct.values) {
        expect(ForecastProduct.fromId(product.id), product);
      }
    });

    test('ids are unique', () {
      final ids = ForecastProduct.values.map((p) => p.id).toSet();
      expect(ids.length, ForecastProduct.values.length);
    });

    test('fromId throws on an unknown value', () {
      expect(
        () => ForecastProduct.fromId('not_a_product'),
        throwsArgumentError,
      );
    });
  });
}
