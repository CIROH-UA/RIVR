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
}
