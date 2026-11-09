// PHASE 2 BASELINE — MUST FAIL against HEAD b2aa2ac.
//
// Defect #3 (audit D1). `NoaaApiService.fetchReturnPeriods`
// (lib/services/4_infrastructure/api/noaa_api_service.dart:233-245) returns
// `[]` for a 404, for every non-200, AND from a catch-all that swallows
// timeouts, socket errors and malformed bodies alike. A transport failure and
// "this reach genuinely has no thresholds" are indistinguishable.
//
// `NwmDataSource.fetch` (:210-216) wraps that `[]` in an ordinary successful
// SourceFetchResult, and `NwmDataSource.validUntil` (:101-105) gives
// returnPeriods a THIRTY-DAY window. `RiverDataRepository._doFetch`
// (:347-351) caches it and `_judge`s it CONFIRMED — `maxHold` is 32 days
// (hold_policy.dart:70) and `maxRunAge` has no entry for the product, so
// `runTooOld` returns false by design.
//
// Net effect: one transient failure removes flood risk from that river for a
// month. The category reads NoData/Unknown, the badge and the card animation
// go flat, the gauge has no zones, and SyncStatusBanner stays silent the
// whole time because the entry is marked current. No later read retries.
//
// What SHOULD happen, any one of which makes this test pass:
//   * a transport failure propagates instead of becoming `[]`; or
//   * an empty result is not given the 30-day static window; or
//   * the key is marked unconfirmed so the banner fires and a read retries.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/4_infrastructure/api/noaa_api_service.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/4_infrastructure/river_data/narrow_nwm_payloads.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';
import 'package:rivr/services/4_infrastructure/shared/flow_unit_preference_service.dart';

import '_phase2_fakes.dart';

const _key = RiverDataKey(
  source: ForecastSource.nwm,
  reachId: '10376605',
  product: ForecastProduct.returnPeriods,
);

void main() {
  late FlowUnitPreferenceService unit;
  late ScriptedNoaa noaa;
  late MemoryCache cache;
  late RiverDataRepository repo;

  setUp(() {
    unit = FlowUnitPreferenceService()..setFlowUnit('CFS');
    // A real transport failure, not the empty list the old code turned one
    // into. See ScriptedNoaa.failWith.
    noaa = ScriptedNoaa(<dynamic>[]);
    cache = MemoryCache();
    repo = RiverDataRepository(
      cache: cache,
      registry: SourceRegistry([
        NwmDataSource(
          api: noaa,
          forecastService: UnusedForecastService(),
          unitService: unit,
          geocoder: NullGeocoder(),
        )
      ]),
    );
  });

  test('control: the happy path really does decode thresholds', () async {
    noaa.returnPeriodResult = [
      {
        'feature_id': 10376605,
        'return_period_2': 10.0,
        'return_period_5': 20.0,
        'return_period_10': 30.0,
        'return_period_25': 40.0,
      }
    ];
    final entry = await repo.read(_key);
    expect(ReturnPeriodPayload.decode(entry!, unit), isNotNull);
  });

  test('a failed return-period fetch is not cached at all', () async {
    noaa.failWith = ReturnPeriodsUnavailable('10376605', 'simulated timeout');

    await expectLater(repo.read(_key), throwsA(isA<ReturnPeriodsUnavailable>()),
        reason: 'the fetch failed, so the read must fail. It used to return '
            'an empty thresholds list indistinguishable from "this reach '
            'genuinely has none"');

    expect(await cache.get(_key), isNull,
        reason: 'nothing may be cached from a failure. The old empty list '
            'was given the near-static THIRTY-DAY window and judged '
            'confirmed, so one transient timeout removed flood risk from '
            'this river for a month');
  });

  test('a failed return-period fetch withdraws the freshness claim', () async {
    noaa.failWith = ReturnPeriodsUnavailable('10376605', 'simulated timeout');
    await expectLater(repo.read(_key), throwsA(isA<ReturnPeriodsUnavailable>()));

    expect(repo.outOfSync.value, isTrue,
        reason: 'Phase 7 made silence a positive claim that the value is '
            'current. After a failure the app may not make that claim, and '
            'SyncStatusBanner is what tells the user');
  });

  test('once upstream recovers, the very next read fetches again', () async {
    noaa.failWith = ReturnPeriodsUnavailable('10376605', 'simulated timeout');
    await expectLater(repo.read(_key), throwsA(isA<ReturnPeriodsUnavailable>()));
    final callsAfterFailure = noaa.returnPeriodCalls;

    noaa.failWith = null;
    noaa.returnPeriodResult = [
      {
        'feature_id': 10376605,
        'return_period_2': 10.0,
        'return_period_5': 20.0,
        'return_period_10': 30.0,
        'return_period_25': 40.0,
        'return_period_50': 50.0,
        'return_period_100': 60.0,
      }
    ];

    final entry = await repo.read(_key);
    expect(noaa.returnPeriodCalls, greaterThan(callsAfterFailure),
        reason: 'the failure must not have been pinned for 30 days; the next '
            'read has to go and ask again');
    expect(entry, isNotNull);
    expect((entry!.payload['returnPeriods'] as List), isNotEmpty);
  });

  test('control: a reach that genuinely has NO thresholds is still cached',
      () async {
    // Upstream answered. Empty is the truth here, and caching it for the
    // full static window is correct — otherwise every such reach refetches
    // on every read forever. This control is what stops the fix above being
    // implemented as "never cache an empty list".
    noaa.returnPeriodResult = <dynamic>[];
    final entry = await repo.read(_key);

    expect(entry, isNotNull);
    expect(entry!.payload['returnPeriods'], isEmpty);
    final days =
        entry.window.validUntil.difference(entry.window.fetchedAt).inDays;
    expect(days, greaterThan(20),
        reason: 'a real "no thresholds" answer keeps the near-static window');
  });

}
