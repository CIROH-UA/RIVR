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

    // ADR 0011 Phase 2 (round 7): the fallback decision is made HERE, in one
    // derivation with the stamp itself — round 7 caught a separate
    // re-derivation accepting a malformed forecast_date that the stamp parser
    // had rejected, so a wall-clock stamp was flagged genuine and a run id
    // minted from it. These drive the real parser, not a fake's boolean.
    group('generation identity', () {
      test('a well-formed forecast_date is genuine', () async {
        final unit = FlowUnitPreferenceService();
        final client = MockClient((req) async =>
            http.Response(fx('proxy_210230337.json'), 200));
        final svc = GeoglowsApiService(client: client, unitService: unit);

        final f = await svc.fetchForecast('210230337');

        expect(f.generatedAtIsFallback, isFalse);
        expect(f.generatedAt.toUtc(), DateTime.utc(2026, 7, 2));
      });

      test('a MALFORMED forecast_date with parseable timestamps is still '
          'genuine — identified by the first step', () async {
        final unit = FlowUnitPreferenceService();
        final client = MockClient((req) async => http.Response(
            '{"forecast_date":"07/02/26","forecast":{'
            '"datetime":["2026-07-02T03:00:00Z","2026-07-02T06:00:00Z"],'
            '"flow_median":[1.0,2.0],'
            '"flow_uncertainty_lower":[0.5,1.0],'
            '"flow_uncertainty_upper":[2.0,3.0]}}',
            200));
        final svc = GeoglowsApiService(client: client, unitService: unit);

        final f = await svc.fetchForecast('210230337');

        expect(f.generatedAtIsFallback, isFalse,
            reason: 'the first timestamp is deterministic across refetches — '
                'a valid run identity');
        expect(f.generatedAt.toUtc(), DateTime.utc(2026, 7, 2, 3));
      });

      test('no stamp of any kind is a wall-clock fallback', () async {
        final unit = FlowUnitPreferenceService();
        final client = MockClient((req) async => http.Response(
            '{"forecast_date":"07/02/26","forecast":{'
            '"datetime":["not-a-time","also-not"],'
            '"flow_median":[1.0,2.0],'
            '"flow_uncertainty_lower":[0.5,1.0],'
            '"flow_uncertainty_upper":[2.0,3.0]}}',
            200));
        final svc = GeoglowsApiService(client: client, unitService: unit);

        final f = await svc.fetchForecast('210230337');

        expect(f.generatedAtIsFallback, isTrue,
            reason: 'nothing in this response identifies the run; flagging '
                'the wall clock as genuine mints a fake run id downstream');
      });
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

  group('GeoglowsApiService.fetchReachCoords', () {
    test('hits the coords proxy and returns {lat, lon}', () async {
      final unit = FlowUnitPreferenceService();
      final client = MockClient((req) async {
        expect(req.url.toString(), contains('geoglows_reach_coords'));
        expect(req.url.toString(), contains('river_id=440380672'));
        return http.Response(
          '{"river_id":440380672,"lat":16.737556,"lon":77.121667}',
          200,
        );
      });
      final svc = GeoglowsApiService(client: client, unitService: unit);

      final coords = await svc.fetchReachCoords('440380672');

      expect(coords, isNotNull);
      expect(coords!.lat, closeTo(16.737556, 1e-6));
      expect(coords.lon, closeTo(77.121667, 1e-6));
    });

    test('returns null when the reach is not found (best-effort)', () async {
      final unit = FlowUnitPreferenceService();
      final client = MockClient(
        (req) async => http.Response('{"error":"river_id 1 not found"}', 404),
      );
      final svc = GeoglowsApiService(client: client, unitService: unit);

      expect(await svc.fetchReachCoords('1'), isNull);
    });

    test('returns null when coordinates are missing from the body', () async {
      final unit = FlowUnitPreferenceService();
      final client = MockClient(
        (req) async => http.Response('{"river_id":5}', 200),
      );
      final svc = GeoglowsApiService(client: client, unitService: unit);

      expect(await svc.fetchReachCoords('5'), isNull);
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
