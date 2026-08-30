// test/services/4_infrastructure/river_data/data_sources_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_data_source.dart';

class _FakeNoaa implements INoaaApiService {
  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> fetchCurrentFlowOnly(String reachId) async {
    calls.add('current:$reachId');
    // Production delegates to fetchForecast('short_range'); mirror that so
    // the payload shape (and its referenceTime) is the one the run-id
    // extraction actually meets.
    return fetchForecast(reachId, 'short_range', isOverview: true);
  }

  @override
  Future<Map<String, dynamic>> fetchForecast(
    String reachId,
    String series, {
    bool isOverview = false,
  }) async {
    calls.add('forecast:$series:$reachId');
    // The FULL multi-section response with a DISTINCT referenceTime per
    // section — the shape the unfiltered fallback actually returns. Round 6
    // proved a single-section fake structurally blind to the extraction
    // stamping mediumRange with shortRange's run.
    return {
      'reach': {'reachId': reachId},
      'shortRange': {
        'series': {
          'referenceTime': '2026-08-23T12:00:00',
          'units': 'ft³/s',
          'data': <dynamic>[],
        },
      },
      'mediumRange': {
        'member1': {
          'referenceTime': '2026-08-23T06:00:00',
          'units': 'ft³/s',
          'data': <dynamic>[],
        },
      },
      'longRange': {
        'member1': {
          'referenceTime': '2026-08-23T00:00:00',
          'units': 'ft³/s',
          'data': <dynamic>[],
        },
      },
    };
  }

  @override
  Future<List<dynamic>> fetchReturnPeriods(String reachId) async {
    calls.add('rp:$reachId');
    return [2, 5, 10];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counts calls so "does not geocode" is observable rather than inferred.
class _CountingGeocoder implements IGeocodingService {
  int calls = 0;

  @override
  Future<Map<String, String?>> reverseGeocode(double lat, double lon) async {
    calls++;
    return {'city': 'Provo', 'state': 'UT', 'country': 'US'};
  }

  @override
  Future<String?> placeLabel(double? lat, double? lon) async {
    calls++;
    return 'Provo, UT';
  }
}

class _FakeForecast implements IForecastService {
  int detailCalls = 0;
  int basicCalls = 0;

  @override
  Future<ReachData> loadBasicReachInfo(String reachId) async {
    basicCalls++;
    // NwmDataSource has no geocode fallback — that is the point of the
    // injected-but-unused geocoder. city/state are set only so the reach looks
    // realistic.
    return ReachData(
      reachId: reachId,
      riverName: 'Test River',
      latitude: 40.0,
      longitude: -111.0,
      city: 'Provo',
      state: 'UT',
      availableForecasts: const ['short_range'],
      cachedAt: DateTime.utc(2026, 8, 22, 12),
    );
  }


  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeGeoglows implements IGeoglowsApiService {
  final List<String> calls = [];

  /// The degraded-response shape: no generation stamp anywhere, so the API
  /// layer stamped wall-clock and flagged it.
  bool generatedAtIsFallback = false;

  @override
  Future<GeoglowsForecast> fetchForecast(String riverId) async {
    calls.add('gforecast:$riverId');
    return GeoglowsForecast(
      riverId: riverId,
      unit: 'ft³/s',
      generatedAt: DateTime.utc(2026, 7, 10, 0, 0),
      generatedAtIsFallback: generatedAtIsFallback,
      points: [
        GeoglowsForecastPoint(
          validTime: DateTime.utc(2026, 7, 10, 3),
          median: 10,
          lower: 8,
          upper: 12,
        ),
        GeoglowsForecastPoint(
          validTime: DateTime.utc(2026, 7, 10, 6),
          median: 11,
          lower: 9,
          upper: 13,
        ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUnit implements IFlowUnitPreferenceService {
  _FakeUnit(this._unit);
  final String _unit;
  @override
  String get currentFlowUnit => _unit;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  runIdTests();
  group('NwmDataSource', () {
    late _FakeNoaa api;
    late _FakeForecast forecast;
    late _CountingGeocoder geocoder;
    late NwmDataSource nwm;

    setUp(() {
      api = _FakeNoaa();
      forecast = _FakeForecast();
      geocoder = _CountingGeocoder();
      nwm = NwmDataSource(
        api: api,
        forecastService: forecast,
        unitService: _FakeUnit('CFS'),
        geocoder: geocoder,
      );
    });

    test('identifies as NWM and supports the NWM products', () {
      expect(nwm.source, ForecastSource.nwm);
      expect(nwm.supportedProducts, contains(ForecastProduct.shortRange));
      expect(nwm.supportedProducts, contains(ForecastProduct.returnPeriods));
      expect(
        nwm.supportedProducts,
        isNot(contains(ForecastProduct.geoglowsForecast)),
      );
    });

    test('validUntil: hourly products round to next top-of-hour + skew', () {
      expect(
        nwm.validUntil(
          ForecastProduct.shortRange,
          DateTime.utc(2026, 7, 10, 12, 30),
        ),
        DateTime.utc(2026, 7, 10, 13, 5),
      );
    });

    test('validUntil: 6-hourly products round to next cycle + skew', () {
      expect(
        nwm.validUntil(
          ForecastProduct.mediumRange,
          DateTime.utc(2026, 7, 10, 13, 10),
        ),
        DateTime.utc(2026, 7, 10, 18, 5),
      );
    });

    test('validUntil: return periods are effectively static (~30 days)', () {
      final now = DateTime.utc(2026, 7, 10, 12, 0);
      expect(
        nwm.validUntil(ForecastProduct.returnPeriods, now),
        now.add(const Duration(days: 30)),
      );
    });

    test('validUntil: reach metadata is static (~30 days)', () {
      // A river's name and coordinates do not change. Untested, this TTL was
      // defended only by a comment.
      final now = DateTime.utc(2026, 7, 10, 12, 0);
      expect(
        nwm.validUntil(ForecastProduct.reachMetadata, now),
        now.add(const Duration(days: 30)),
      );
    });

    test('reachMetadata is advertised as supported', () {
      expect(nwm.supportedProducts, contains(ForecastProduct.reachMetadata));
    });

    test('reachMetadata uses the cheap reach-info call, not the full bundle',
        () async {
      final result = await nwm.fetch(const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.reachMetadata,
      ));
      expect(forecast.basicCalls, 1);
      expect(forecast.detailCalls, 0,
          reason: 'the whole point is avoiding loadReachDetailsData');
      expect(result.payload['riverName'], 'Test River');
      expect(result.payload['latitude'], 40.0);
    });

    // ADR 0011 Phase 1, guard 3 — asserted HERE, at the API layer, because the
    // widget-level guard cannot see it. Review proved that: the sheet's test
    // records reads at the repository, while `reachSummary` pulls medium range
    // two layers further down through ForecastService. A guard scoped above the
    // violation is structurally blind to it.
    test('the narrow products never reach the medium-range endpoint', () async {
      for (final p in [
        ForecastProduct.reachMetadata,
        ForecastProduct.analysisAssimilation,
        ForecastProduct.returnPeriods,
      ]) {
        api.calls.clear();
        await nwm.fetch(RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '23021904',
          product: p,
        ));
        expect(
          api.calls.where((c) => c.contains('medium_range')),
          isEmpty,
          reason: '$p must not drag in the 156 KB series',
        );
      }
    });

    // ADR 0011 — geocoding stays off the critical path.
    //
    // REGRESSION, and the second attempt at this guard. The first asserted on
    // elapsed time on the theory that "a real reverseGeocode cannot return this
    // fast"; review measured one returning in 86 ms, under the 200 ms
    // threshold, and noted that at baseline the timer measured nothing at all.
    // A guard that cannot fail for the right reason is not a guard.
    //
    // The geocoder is now injected, so the assertion is what it should always
    // have been: it was never called.
    test('reachMetadata never geocodes — counted, not timed', () async {
      expect(geocoder.calls, 0, reason: 'precondition');

      await nwm.fetch(const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.reachMetadata,
      ));

      expect(geocoder.calls, 0,
          reason: 'reverseGeocode catches internally and never throws, so on '
              'this path nothing would bound it but a 30 s HTTP timeout — in '
              'front of the cheapest call in the app');
      expect(forecast.basicCalls, 1);
    });

    test('no product on the tap path geocodes', () async {
      for (final p in [
        ForecastProduct.reachMetadata,
        ForecastProduct.analysisAssimilation,
        ForecastProduct.returnPeriods,
      ]) {
        await nwm.fetch(RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '23021904',
          product: p,
        ));
      }
      expect(geocoder.calls, 0);
    });

    test('validUntil throws for unsupported products', () {
      expect(
        () => nwm.validUntil(ForecastProduct.geoglowsForecast, DateTime.now()),
        throwsArgumentError,
      );
    });

    test('fetch maps products to NWM API calls, tagging the current unit',
        () async {
      final short = await nwm.fetch(const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.shortRange,
      ));
      expect(short.unit, 'CFS');
      // The fake now returns the real NOAA nesting (for the run-id tests), so
      // assert on the call made rather than a synthetic echo field.
      expect(api.calls, contains('forecast:short_range:23021904'));

      await nwm.fetch(const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.analysisAssimilation,
      ));
      expect(api.calls, contains('current:23021904'));

      final rp = await nwm.fetch(const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.returnPeriods,
      ));
      expect(rp.payload['returnPeriods'], [2, 5, 10]);
    });

    test('reachSummary is a deleted product — the source rejects it', () {
      expect(
        () => nwm.fetch(const RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '23021904',
          product: ForecastProduct.reachSummary,
        )),
        throwsArgumentError,
        reason: 'the bundle died in Phase 3; a source quietly serving it '
            'again would resurrect the 156 KB tap-path fetch',
      );
    });

    test('fetch throws for an unsupported product', () {
      expect(
        () => nwm.fetch(const RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '1',
          product: ForecastProduct.geoglowsForecast,
        )),
        throwsArgumentError,
      );
    });
  });

  group('GeoglowsDataSource', () {
    late _FakeGeoglows api;
    late GeoglowsDataSource geoglows;

    setUp(() {
      api = _FakeGeoglows();
      geoglows = GeoglowsDataSource(api: api, unitService: _FakeUnit('CFS'));
    });

    test('identifies as GEOGLOWS and supports the forecast product', () {
      expect(geoglows.source, ForecastSource.geoglows);
      expect(geoglows.supportedProducts, {ForecastProduct.geoglowsForecast});
    });

    // GEOGLOWS stamps its run 00Z but PUBLISHES at 10:15-10:30 UTC — measured
    // from S3 Last-Modified on two consecutive days, and the reason the flood
    // builder is scheduled at 11:00. This window used to run to the next
    // MIDNIGHT, conflating the two: a device fetching at 00:20 held the
    // previous day's run for another 24 hours while a newer one had existed
    // since 10:15. Nothing surfaced it until Phase 7's run-age check started
    // warning, correctly, for about six hours a day on the live path.
    group('validUntil follows PUBLICATION, not the run stamp', () {
      test('after publication, waits for tomorrow\'s', () {
        expect(
          geoglows.validUntil(
            ForecastProduct.geoglowsForecast,
            DateTime.utc(2026, 7, 10, 15, 20),
          ),
          DateTime.utc(2026, 7, 11, 10, 45),
        );
      });

      test('before publication, waits for TODAY\'s', () {
        // The old behaviour's worst case: fetching just after midnight used
        // to buy a 24-hour window when the new run was ten hours away.
        expect(
          geoglows.validUntil(
            ForecastProduct.geoglowsForecast,
            DateTime.utc(2026, 7, 10, 0, 20),
          ),
          DateTime.utc(2026, 7, 10, 10, 45),
        );
      });
    });

    group('windowFor uses the run actually received', () {
      test('holding TODAY\'s run waits for tomorrow\'s publication', () {
        expect(
          GeoglowsDataSource.windowFor(
            DateTime.utc(2026, 7, 10, 12, 0),
            DateTime.utc(2026, 7, 10), // today's 00Z run
          ),
          DateTime.utc(2026, 7, 11, 10, 45),
        );
      });

      test('holding YESTERDAY\'s before publication waits for today\'s', () {
        expect(
          GeoglowsDataSource.windowFor(
            DateTime.utc(2026, 7, 10, 6, 0),
            DateTime.utc(2026, 7, 9),
          ),
          DateTime.utc(2026, 7, 10, 10, 45),
        );
      });

      // The bug's second home. Without this, a device that looked just after
      // the expected time and found publication late would sit on yesterday's
      // water until the NEXT day's window — the same failure, one publication
      // later.
      test('holding YESTERDAY\'s AFTER publication retries shortly', () {
        final now = DateTime.utc(2026, 7, 10, 11, 0);
        expect(
          GeoglowsDataSource.windowFor(now, DateTime.utc(2026, 7, 9)),
          now.add(const Duration(minutes: 30)),
        );
      });

      test('no run identity falls back to the publication schedule', () {
        expect(
          GeoglowsDataSource.windowFor(DateTime.utc(2026, 7, 10, 6, 0), null),
          DateTime.utc(2026, 7, 10, 10, 45),
        );
        expect(
          GeoglowsDataSource.windowFor(DateTime.utc(2026, 7, 10, 12, 0), null),
          DateTime.utc(2026, 7, 11, 10, 45),
        );
      });

      // The whole point: the window must never let a held run reach the
      // run-age cap that makes the app warn. 42h is MAX_RUN_AGE_MS.
      test('a held run never reaches the 42h cap that triggers the warning',
          () {
        for (var h = 0; h < 24; h++) {
          final now = DateTime.utc(2026, 7, 10, h, 0);
          final run = DateTime.utc(2026, 7, 10); // today's, once published
          final until = GeoglowsDataSource.windowFor(
            now, now.hour >= 11 ? run : DateTime.utc(2026, 7, 9));
          final runHeld = now.hour >= 11 ? run : DateTime.utc(2026, 7, 9);
          final ageAtExpiry = until.difference(runHeld);
          expect(ageAtExpiry.inHours, lessThan(42),
              reason: 'at $now the window runs to $until, leaving the run '
                  '${ageAtExpiry.inHours}h old — past the cap, so the app '
                  'would warn about data it could have refreshed');
        }
      });
    });

    test('fetch serializes the forecast and tags the canonical unit', () async {
      final result = await geoglows.fetch(const RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '210230337',
        product: ForecastProduct.geoglowsForecast,
      ));
      expect(result.unit, 'CFS'); // canonical token, not the 'ft³/s' label
      final points = result.payload['points'] as List;
      expect(points.length, 2);
      expect((points.first as Map)['median'], 10);
      expect(api.calls, contains('gforecast:210230337'));
    });

    // Mutation-checked, and it mattered: deleting the per-fetch `validUntil`
    // left all 1269 tests green. The schedule-only form would still be used,
    // which is better than the old midnight window but blind to WHICH run came
    // back — so a device handed yesterday's forecast after publication would
    // hold it a full day instead of looking again shortly.
    test('fetch supplies a window computed from the run it received',
        () async {
      final result = await geoglows.fetch(const RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '210230337',
        product: ForecastProduct.geoglowsForecast,
      ));

      expect(result.validUntil, isNotNull,
          reason: 'without this the repository falls back to the '
              'schedule-only window and loses the run-awareness entirely');

      // The fake reports the 2026-07-10 00Z run, which is far in the past, so
      // `windowFor` takes its late-publication branch and returns
      // `now + 30 minutes` — a MOVING target. Comparing against a second call
      // to `windowFor(DateTime.now(), ...)` therefore compares two instants a
      // few milliseconds apart.
      //
      // That is a real flake and CI caught it: run before 10:45 UTC the branch
      // returns a FIXED instant (today's publication) and the two agree, so it
      // passed locally at 05:00 and failed on CI at 14:20. Asserted with a
      // tolerance instead of exact equality, and the tolerance is the point of
      // the test — the value must track `now`, not the next midnight.
      final before = DateTime.now().toUtc();
      final expected =
          GeoglowsDataSource.windowFor(before, DateTime.utc(2026, 7, 10));
      final skew = result.validUntil!.difference(expected).abs();

      expect(skew, lessThan(const Duration(seconds: 5)),
          reason: 'expected roughly $expected, got ${result.validUntil}');

      // And the property that actually matters, asserted with NO CLOCK IN IT.
      //
      // Two previous attempts both smuggled the wall clock into this
      // assertion and both were wrong at a different hour of the day:
      //
      //   1. compared against the next midnight  -> failed 23:30-24:00 UTC,
      //      because the late-retry branch returns `now + 30 min`.
      //   2. bounded the gap to under an hour    -> failed 00:00-10:45 UTC,
      //      because BEFORE the publication time the branch returns a fixed
      //      instant (today's 10:45) rather than `now + 30 min`, so the gap
      //      is up to ten hours and legitimately so.
      //
      // Measured, not reasoned: gap is 615 min at 00:30Z, 285 min at 06:00Z,
      // 1 min at 10:44Z, then 30 min from 10:46Z onward. Attempt 2 was
      // WORSE than attempt 1 — half an hour of daily breakage became eleven.
      //
      // So the assertion is now against `windowFor` itself at a FIXED instant,
      // which is what the test is really about: `fetch` must ask the same
      // question `windowFor` answers, for the run it actually received.
      const fixedNow = '2026-07-11T15:00:00Z';
      expect(
        GeoglowsDataSource.windowFor(
            DateTime.parse(fixedNow), DateTime.utc(2026, 7, 10)),
        DateTime.parse(fixedNow).add(const Duration(minutes: 30)),
        reason: 'a run from a previous day, checked after publication time, '
            'must be re-checked shortly — not held until the next midnight, '
            'which is the bug this fixed',
      );
    });

    test('a fallback run stamp yields the schedule-only window', () async {
      // No run identity means we cannot tell which run this is, so there is
      // nothing better than the publication schedule — and inventing one is
      // what `generatedAtIsFallback` exists to prevent.
      final fallbackApi = _FakeGeoglows()..generatedAtIsFallback = true;
      final src = GeoglowsDataSource(
        api: fallbackApi,
        unitService: _FakeUnit('CFS'),
      );
      final result = await src.fetch(const RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '210230337',
        product: ForecastProduct.geoglowsForecast,
      ));

      expect(result.runId, isNull);
      expect(result.validUntil,
          GeoglowsDataSource.windowFor(DateTime.now().toUtc(), null));
    });
  });
}
// ADR 0011 Phase 2 (round 5): entries record the run they came from. The
// extraction lives in the sources; these pin the two shapes.
void runIdTests() {
  group('run identity', () {
    test('NWM: each product records ITS OWN section\'s referenceTime',
        () async {
      final api = _FakeNoaa();
      final src = NwmDataSource(
        geocoder: _CountingGeocoder(),
        api: api,
        forecastService: _FakeForecast(),
        unitService: _FakeUnit('CFS'),
      );
      RiverDataKey k(ForecastProduct p) => RiverDataKey(
          source: ForecastSource.nwm, reachId: '123', product: p);

      final short = await src.fetch(k(ForecastProduct.shortRange));
      final medium = await src.fetch(k(ForecastProduct.mediumRange));
      final long = await src.fetch(k(ForecastProduct.longRange));

      expect(short.runId, '2026-08-23T12:00:00');

      // analysisAssimilation is the most-read runId in the app — the sheet's
      // and forecast page's current flow. Its data IS the short_range series
      // (fetchCurrentFlowOnly delegates there), so it records that run.
      final aa = await src.fetch(k(ForecastProduct.analysisAssimilation));
      expect(aa.runId, '2026-08-23T12:00:00',
          reason: 'unguarded, round 7 nulled it with the suite green');
      expect(medium.runId, '2026-08-23T06:00:00',
          reason: 'the unfiltered fallback returns every section; first-found '
              'stamped this with shortRange\'s run, which advances hourly '
              'while medium range moves 4×/day — supersession lying');
      expect(long.runId, '2026-08-23T00:00:00');
    });

    test('NWM: a payload with no referenceTime yields null, not a fake',
        () async {
      final api = _FakeNoaa();
      final src = NwmDataSource(
        geocoder: _CountingGeocoder(),
        api: api,
        forecastService: _FakeForecast(),
        unitService: _FakeUnit('CFS'),
      );

      final result = await src.fetch(const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '123',
        product: ForecastProduct.returnPeriods,
      ));

      expect(result.runId, isNull);
    });

    test('GEOGLOWS: the generation date is the run', () async {
      final src = GeoglowsDataSource(
        api: _FakeGeoglows(),
        unitService: _FakeUnit('CFS'),
      );

      final result = await src.fetch(const RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '760021642',
        product: ForecastProduct.geoglowsForecast,
      ));

      expect(result.runId, DateTime.utc(2026, 7, 10).toIso8601String());
    });

    // REGRESSION (round 6, F3): when the response carries no generation stamp
    // the API layer falls back to wall-clock — and minting a run from that
    // makes every refetch of identical data look like a new run. NWM's side
    // states this rule in a comment; GEOGLOWS did the opposite.
    test('GEOGLOWS: a wall-clock fallback stamp yields NO run id', () async {
      final api = _FakeGeoglows()..generatedAtIsFallback = true;
      final src = GeoglowsDataSource(
        api: api,
        unitService: _FakeUnit('CFS'),
      );

      final result = await src.fetch(const RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '760021642',
        product: ForecastProduct.geoglowsForecast,
      ));

      expect(result.runId, isNull,
          reason: 'a fabricated run is worse than none — supersession lies');
    });
  });
}
