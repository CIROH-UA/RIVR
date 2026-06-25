// test/services/4_infrastructure/api/geoglows_api_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivr/services/4_infrastructure/api/geoglows_api_service.dart';
import 'package:rivr/services/4_infrastructure/shared/flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

/// Uses real (trimmed) GEOGLOWS responses captured from the live API so the
/// parser is exercised against the true response shape — including the `''`
/// gaps in the ensemble arrays and the native m³/s -> CFS conversion.
void main() {
  String fx(String name) =>
      File('test/fixtures/geoglows/$name').readAsStringSync();

  const cmsToCfs = 35.3147;

  group('GeoglowsApiService.fetchForecast', () {
    test('parses points and converts native m³/s to CFS by default', () async {
      final unit = FlowUnitPreferenceService(); // defaults to CFS
      final client = MockClient((req) async {
        expect(req.url.toString(), contains('/forecast/210066600'));
        return http.Response(fx('forecast_210066600.json'), 200);
      });
      final svc = GeoglowsApiService(client: client, unitService: unit);

      final f = await svc.fetchForecast('210066600');

      expect(f.riverId, '210066600');
      expect(f.unit, 'ft³/s');
      expect(f.points.length, 4);
      // First median in the fixture is 39.3 m³/s.
      expect(f.currentMedian, closeTo(39.3 * cmsToCfs, 0.1));
      expect(f.points.first.validTime.toUtc(), DateTime.utc(2026, 6, 25, 0));
      // Uncertainty bounds are present and converted too.
      expect(f.points.first.lower, closeTo(39.3 * cmsToCfs, 0.1));
    });

    test('keeps native m³/s when the preference is CMS', () async {
      final unit = FlowUnitPreferenceService()..setFlowUnit('CMS');
      final client = MockClient(
        (req) async => http.Response(fx('forecast_210066600.json'), 200),
      );
      final svc = GeoglowsApiService(client: client, unitService: unit);

      final f = await svc.fetchForecast('210066600');

      expect(f.unit, 'm³/s');
      expect(f.currentMedian, closeTo(39.3, 0.001));
    });

    test('surfaces GEOGLOWS error bodies (HTTP 200 + {error}) as failures',
        () async {
      final unit = FlowUnitPreferenceService();
      final client = MockClient(
        (req) async => http.Response(
          '{"error":"No variable named \'logpearson3\'"}',
          200,
        ),
      );
      final svc = GeoglowsApiService(client: client, unitService: unit);

      expect(() => svc.fetchForecast('1'), throwsA(isA<ServiceException>()));
    });
  });

  group('GeoglowsApiService.fetchEnsembleStats', () {
    test('skips empty-string gaps in the ensemble arrays', () async {
      final unit = FlowUnitPreferenceService()..setFlowUnit('CMS');
      final client = MockClient(
        (req) async => http.Response(fx('forecaststats_210066600.json'), 200),
      );
      final svc = GeoglowsApiService(client: client, unitService: unit);

      final e = await svc.fetchEnsembleStats('210066600');

      // The fixture has 6 steps but only indices 0 and 3 carry ensemble values.
      expect(e.points.length, 2);
      expect(e.points.first.median, closeTo(39.3, 0.001));
      expect(e.points[1].median, closeTo(39.1, 0.001));
      // min/p25/p75/max are populated (not collapsed to the median).
      expect(e.points.first.max, isNotNull);
    });
  });
}
