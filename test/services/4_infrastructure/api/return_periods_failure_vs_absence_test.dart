// test/services/4_infrastructure/api/return_periods_failure_vs_absence_test.dart
//
// The companion guard to return_period_failure_test.dart, and the reason it
// exists is worth recording.
//
// That test proves the REPOSITORY does the right thing when a return-period
// fetch throws: nothing is cached, the freshness claim is withdrawn, the next
// read retries. But it drives a FAKE NoaaApiService, so it says nothing about
// whether the real one ever throws. A break-it review on 2026-11-09 mutated
// the real service three ways — reverting the catch to `return []`, gutting
// the non-200 throw with `if (false)`, and throwing on a genuine 404 — and
// ALL THREE left that test green.
//
// That is the exact defect an audit of this suite measured the week before:
// guards that test a reimplementation rather than production code. This file
// drives the real `NoaaApiService` over a stubbed transport so the three
// mutations above are caught.
//
// The distinction under test, which is the whole point:
//   * upstream ANSWERED and this reach has no thresholds  -> `[]`, cacheable
//   * we did not find out                                 -> throw, never cached
//
// Collapsing those two let one transient timeout remove flood risk from a
// river for thirty days, in a flood app.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/api/noaa_api_service.dart';

class _Cfs implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  double convertFlow(double v, String from, String to) => v;
  @override
  double convertToPreferredUnit(double v, String from) => v;
  @override
  double convertFromPreferredUnit(double v, String to) => v;
  @override
  String normalizeUnit(String u) => u;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

NoaaApiService serviceThat(Future<http.Response> Function(http.Request) handler) =>
    NoaaApiService(client: MockClient(handler), unitService: _Cfs());

const _reach = '10376605';

void main() {
  group('a real answer of "no thresholds"', () {
    test('404 returns an empty list and does NOT throw', () async {
      final api = serviceThat((_) async => http.Response('not found', 404));

      final got = await api.fetchReturnPeriods(_reach);

      expect(got, isEmpty,
          reason: 'upstream knows this reach and has none. That is a fact, '
              'and the caller may cache it for the full static window — '
              'otherwise every such reach refetches on every read forever');
    });
  });

  group('NOT an answer', () {
    test('a 500 throws rather than looking like "no thresholds"', () async {
      final api = serviceThat((_) async => http.Response('boom', 500));

      await expectLater(
        api.fetchReturnPeriods(_reach),
        throwsA(isA<ReturnPeriodsUnavailable>()),
        reason: 'this used to return [], which travels on as a successful '
            'empty result and is pinned for 30 days',
      );
    });

    test('a transport failure throws', () async {
      final api = serviceThat((_) async => throw const SocketishError());

      await expectLater(
        api.fetchReturnPeriods(_reach),
        throwsA(isA<ReturnPeriodsUnavailable>()),
        reason: 'a timeout, a dropped socket or a malformed body are all '
            '"we did not find out", and the catch-all used to swallow every '
            'one of them into an empty list',
      );
    });

    test('a 200 carrying unparseable junk throws', () async {
      final api = serviceThat((_) async => http.Response('<html>nope', 200));

      await expectLater(
        api.fetchReturnPeriods(_reach),
        throwsA(isA<ReturnPeriodsUnavailable>()),
      );
    });
  });

  group('the happy path still works', () {
    test('200 with thresholds decodes them', () async {
      final api = serviceThat((_) async => http.Response(
            jsonEncode({
              'return_period_2': 10.0,
              'return_period_5': 20.0,
              'return_period_10': 30.0,
              'return_period_25': 40.0,
              'return_period_50': 50.0,
              'return_period_100': 60.0,
            }),
            200,
          ));

      final got = await api.fetchReturnPeriods(_reach);

      expect(got, isNotEmpty,
          reason: 'the control. Without it, "throw on everything" would pass '
              'every test above');
    });
  });
}

/// Stands in for a socket/timeout failure from the transport.
class SocketishError implements Exception {
  const SocketishError();
}
