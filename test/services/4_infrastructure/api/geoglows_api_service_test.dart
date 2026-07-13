// test/services/4_infrastructure/api/geoglows_api_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivr/services/4_infrastructure/api/geoglows_api_service.dart';
import 'package:rivr/services/4_infrastructure/shared/flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

/// Uses a real (trimmed) response captured from the GEOGLOWS proxy Cloud
/// Function, so the parser is exercised against the true payload shape:
/// nested `forecast`/`ensemble` objects, native m³/s, and null gaps in the
/// ensemble arrays (NaN -> null server-side).
void main() {
  String fx(String name) =>
      File('test/fixtures/geoglows/$name').readAsStringSync();

  const cmsToCfs = 35.3147;

  group('GeoglowsApiService.fetchForecast', () {
    test('hits the proxy and converts native m³/s to CFS by default', () async {
      final unit = FlowUnitPreferenceService(); // defaults to CFS
      final client = MockClient((req) async {
        expect(req.url.toString(), contains('river_id=210230337'));
        return http.Response(fx('proxy_210230337.json'), 200);
      });
      final svc = GeoglowsApiService(client: client, unitService: unit);

      final f = await svc.fetchForecast('210230337');

      expect(f.riverId, '210230337');
      expect(f.unit, 'ft³/s');
      expect(f.points.length, 4);
      // First median in the fixture is 41.46 m³/s. (currentMedian picks the
      // step closest to *now*, which is undefined against a fixed fixture, so
      // assert the conversion on the stable first point.)
      expect(f.points.first.median, closeTo(41.46 * cmsToCfs, 0.1));
      // generatedAt derives from forecast_date (20260702).
      expect(f.generatedAt.toUtc(), DateTime.utc(2026, 7, 2));
      expect(f.points.first.lower, closeTo(41.46 * cmsToCfs, 0.1));
    });

    test('keeps native m³/s when the preference is CMS', () async {
      final unit = FlowUnitPreferenceService()..setFlowUnit('CMS');
      final client = MockClient(
        (req) async => http.Response(fx('proxy_210230337.json'), 200),
      );
      final svc = GeoglowsApiService(client: client, unitService: unit);

      final f = await svc.fetchForecast('210230337');

      expect(f.unit, 'm³/s');
      expect(f.points.first.median, closeTo(41.46, 0.001));
    });

    test('surfaces proxy error bodies as failures', () async {
      final unit = FlowUnitPreferenceService();
      final client = MockClient(
        (req) async => http.Response(
          '{"error":"no forecast for river_id 1"}',
          502,
        ),
      );
      final svc = GeoglowsApiService(client: client, unitService: unit);

      expect(() => svc.fetchForecast('1'), throwsA(isA<ServiceException>()));
    });
  });

  group('GeoglowsApiService.fetchEnsembleStats', () {
    test('reads the ensemble object and skips null gaps', () async {
      final unit = FlowUnitPreferenceService()..setFlowUnit('CMS');
      final client = MockClient(
        (req) async => http.Response(fx('proxy_210230337.json'), 200),
      );
      final svc = GeoglowsApiService(client: client, unitService: unit);

      final e = await svc.fetchEnsembleStats('210230337');

      // 6 steps in the fixture, only indices 0 and 3 carry ensemble values.
      expect(e.points.length, 2);
      expect(e.points.first.median, closeTo(41.46, 0.001));
      expect(e.points[1].median, closeTo(41.32, 0.001));
    });
  });
}
