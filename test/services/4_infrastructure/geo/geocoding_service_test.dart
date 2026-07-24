// test/services/4_infrastructure/geo/geocoding_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/4_infrastructure/geo/geocoding_service.dart';

void main() {
  group('GeocodingService.formatPlace', () {
    test('US reach formats as "City, ST"', () {
      expect(
        GeocodingService.formatPlace(
            {'city': 'Monroe City', 'state': 'IN', 'country': 'United States'}),
        'Monroe City, IN',
      );
    });

    test('non-US reach formats as "City, Country"', () {
      expect(
        GeocodingService.formatPlace(
            {'city': 'Castilla', 'state': 'Piura', 'country': 'Peru'}),
        'Castilla, Peru',
      );
    });

    test('"United States of America" is also treated as US', () {
      expect(
        GeocodingService.formatPlace({
          'city': 'Provo',
          'state': 'UT',
          'country': 'United States of America'
        }),
        'Provo, UT',
      );
    });

    test('no city falls back to the country', () {
      expect(
        GeocodingService.formatPlace(
            {'city': null, 'state': null, 'country': 'France'}),
        'France',
      );
    });

    test('US with a missing state falls back to "City, Country"', () {
      expect(
        GeocodingService.formatPlace(
            {'city': 'Somewhere', 'state': null, 'country': 'United States'}),
        'Somewhere, United States',
      );
    });

    test('nothing usable returns null', () {
      expect(
        GeocodingService.formatPlace(
            {'city': null, 'state': null, 'country': null}),
        isNull,
      );
      expect(GeocodingService.formatPlace({}), isNull);
    });
  });
}
