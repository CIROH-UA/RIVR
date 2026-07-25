// test/services/4_infrastructure/map/stream_conditions_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivr/services/4_infrastructure/map/stream_conditions_service.dart';

void main() {
  group('StreamConditionsService.fetchConditions', () {
    test('parses the conditions blob into {stationId: category}', () async {
      final client = MockClient((req) async {
        expect(req.url.toString(), contains('vpu=614'));
        return http.Response(
          '{"vpu":614,"date":"20260724","count":2,'
          '"conditions":{"670004548":4,"670046597":1}}',
          200,
        );
      });
      final svc = StreamConditionsService(client: client);

      final c = await svc.fetchConditions(614);

      expect(c, {670004548: 4, 670046597: 1});
    });

    test('returns empty map on a non-200 (best-effort)', () async {
      final client = MockClient(
        (req) async => http.Response('{"error":"unknown vpu 999"}', 404),
      );
      final svc = StreamConditionsService(client: client);

      expect(await svc.fetchConditions(999), isEmpty);
    });

    test('returns empty map when the body has no conditions object', () async {
      final client = MockClient((req) async => http.Response('{"vpu":614}', 200));
      final svc = StreamConditionsService(client: client);

      expect(await svc.fetchConditions(614), isEmpty);
    });

    test('skips malformed entries rather than throwing', () async {
      final client = MockClient(
        (req) async => http.Response(
          '{"conditions":{"670004548":4,"bad":2,"670002503":"3"}}',
          200,
        ),
      );
      final svc = StreamConditionsService(client: client);

      // "bad" key is unparseable (dropped); "3" string value parses to int.
      expect(await svc.fetchConditions(614), {670004548: 4, 670002503: 3});
    });
  });

  group('StreamConditionsService.fetchByStation', () {
    test('resolves the region from a station id and returns vpu + conditions',
        () async {
      final client = MockClient((req) async {
        expect(req.url.toString(), contains('station_id=670008640'));
        return http.Response(
          '{"vpu":614,"date":"20260724","count":2,'
          '"conditions":{"670008640":4,"670005194":1}}',
          200,
        );
      });
      final svc = StreamConditionsService(client: client);

      final res = await svc.fetchByStation(670008640);

      expect(res, isNotNull);
      expect(res!.vpu, 614);
      expect(res.conditions, {670008640: 4, 670005194: 1});
    });

    test('returns null when the reach is not found', () async {
      final client = MockClient(
        (req) async => http.Response('{"error":"unknown station_id 1"}', 404),
      );
      final svc = StreamConditionsService(client: client);

      expect(await svc.fetchByStation(1), isNull);
    });

    test('returns null when the response omits the vpu', () async {
      final client = MockClient(
        (req) async => http.Response('{"conditions":{"5":2}}', 200),
      );
      final svc = StreamConditionsService(client: client);

      expect(await svc.fetchByStation(5), isNull);
    });
  });

  group('StreamConditionsService.fetchNwmByStations', () {
    test('sends the visible reach ids and parses the conditions', () async {
      final client = MockClient((req) async {
        expect(req.url.toString(), contains('station_ids=3716996,24561403,101'));
        return http.Response(
          '{"date":"20260725","count":2,'
          '"conditions":{"3716996":4,"24561403":1}}',
          200,
        );
      });
      final svc = StreamConditionsService(client: client);

      final c = await svc.fetchNwmByStations([3716996, 24561403, 101]);

      expect(c, {3716996: 4, 24561403: 1});
    });

    test('returns empty for an empty id list without hitting the network',
        () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('{}', 200);
      });
      final svc = StreamConditionsService(client: client);

      expect(await svc.fetchNwmByStations(const []), isEmpty);
      expect(called, isFalse);
    });
  });
}
