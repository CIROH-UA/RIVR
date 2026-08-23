// test/services/4_infrastructure/forecast/weekly_outlook_service_test.dart
//
// There was no test for this service at all. Review round 11 proved what that
// cost by mutating it four ways and leaving the suite green every time:
//
//  * restoring `location: await _locationLabel(...)` — the geocode back on the
//    build path, blocking the page per row (the ADR 0010 defect this phase
//    exists to fix);
//  * dropping the CMS→display conversion on return periods, which for a CFS
//    user shrinks every threshold ~35× and pushes essentially every river into
//    the top flood category;
//  * replacing `Future.wait` with a serial loop — literally the 3-5 minute
//    stall that opened ADR 0010;
//  * deleting the failure reporting, so a total outage looks like an empty week.
//
// Each of the four has a guard below, and each guard was re-run against its
// mutation before this file was committed.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/forecast/weekly_outlook_service.dart';

/// Real CMS↔CFS arithmetic. An identity stub makes a missing conversion
/// invisible — the mistake this suite already made once on the forecast page.
class _Unit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
  @override
  double convertFlow(double v, String from, String to) {
    if (from == to) return v;
    if (from == 'CMS' && to == 'CFS') return v * 35.3147;
    if (from == 'CFS' && to == 'CMS') return v / 35.3147;
    return v;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Counts geocodes and can be made slow, so "was it awaited on the build path"
/// is answered by *whether it was called*, not by a stopwatch. A timing
/// assertion was tried on another surface and a real Mapbox call came back in
/// 86 ms, under the threshold — it could not fail for the right reason.
class _Geocoder implements IGeocodingService {
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

/// Records call overlap so serial awaits cannot pass as parallel ones.
class _Forecast implements IForecastService {
  _Forecast({
    this.returnPeriods,
    this.delay,
    this.failFor = const {},
  });

  final Map<int, double>? returnPeriods;
  final Duration? delay;
  final Set<String> failFor;

  int _inFlight = 0;
  int maxConcurrent = 0;

  @override
  Future<ForecastResponse> loadCompleteReachData(String reachId) async {
    _inFlight++;
    maxConcurrent = _inFlight > maxConcurrent ? _inFlight : maxConcurrent;
    try {
      if (delay != null) await Future<void>.delayed(delay!);
      if (failFor.contains(reachId)) {
        throw Exception('simulated upstream failure for $reachId');
      }
      final now = DateTime.now().toUtc();
      return ForecastResponse(
        reach: ReachData(
          reachId: reachId,
          riverName: 'Test River $reachId',
          latitude: 40.2,
          longitude: -111.6,
          availableForecasts: const ['medium_range'],
          returnPeriods: returnPeriods,
          cachedAt: now,
        ),
        mediumRange: {
          'mean': ForecastSeries(
            units: 'ft³/s',
            data: [
              for (var i = 1; i <= 8; i++)
                ForecastPoint(
                  validTime: now.add(Duration(days: i)),
                  // 640 CFS ≈ 18.1 CMS.
                  flow: 640,
                ),
            ],
          ),
        },
        longRange: const {},
      );
    } finally {
      _inFlight--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// GEOGLOWS favourites go through the repository, not IForecastService. The
/// branch had no coverage at all: `read` → `refresh` passed, so class (d) —
/// read through the cache the sheet warmed — was asserted on three surfaces
/// and not here.
class _Repo implements IRiverDataRepository {
  _Repo({this.forecast});

  final GeoglowsForecast? forecast;
  final List<RiverDataKey> reads = [];
  final List<RiverDataKey> refreshes = [];

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    reads.add(key);
    if (forecast == null) return null;
    return RiverDataEntry(
      key: key,
      window: FreshnessWindow(
        fetchedAt: DateTime.utc(2026, 8, 23, 12),
        validUntil: DateTime.utc(2026, 8, 23, 13),
      ),
      unit: 'CFS',
      payload: GeoglowsForecastPayload.encode(forecast!),
    );
  }

  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) {
    refreshes.add(key);
    return read(key);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

GeoglowsForecast _geoglowsForecast({
  Map<int, double> returnPeriods = const {2: 5000, 5: 8000, 10: 12000, 25: 20000},
}) {
  final now = DateTime.now().toUtc();
  return GeoglowsForecast(
    riverId: '760021642',
    unit: 'ft³/s',
    generatedAt: now,
    points: [
      for (var i = 1; i <= 8; i++)
        GeoglowsForecastPoint(
          validTime: now.add(Duration(days: i)),
          median: 1000,
          lower: 900,
          upper: 1100,
        ),
    ],
    returnPeriods: returnPeriods,
  );
}

FavoriteRiver _geoFav(String id, {int order = 0}) => FavoriteRiver(
      reachId: id,
      displayOrder: order,
      source: ForecastSource.geoglows,
      latitude: 12.1,
      longitude: 15.3,
    );

FavoriteRiver _fav(String id, {int order = 0}) => FavoriteRiver(
      reachId: id,
      riverName: 'River $id',
      displayOrder: order,
      latitude: 40.2,
      longitude: -111.6,
    );

WeeklyOutlookService _service({
  required _Forecast forecast,
  required _Geocoder geocoder,
  _Repo? repo,
}) =>
    WeeklyOutlookService(
      forecastService: forecast,
      riverData: repo ?? _Repo(),
      unitService: _Unit(),
      geocoder: geocoder,
    );

void main() {
  // REGRESSION (ADR 0010's headline defect): `location:` used to be
  // `await _locationLabel(lat, lon)`. Because buildOutlook waits on every row,
  // one Mapbox hop per favourite gated the whole page — and the only bound on
  // it was a 30 s HTTP timeout.
  test('building an outlook performs no geocoding at all', () async {
    final geocoder = _Geocoder();
    final svc = _service(forecast: _Forecast(), geocoder: geocoder);

    final result = await svc.buildOutlook([_fav('1'), _fav('2', order: 1)]);

    expect(result.rows, hasLength(2));
    expect(geocoder.calls, 0,
        reason: 'a place label is decoration; awaiting it here puts a network '
            'round-trip per favourite in front of the page render');
    expect(result.rows.every((r) => r.location == null), isTrue);
  });

  test('the label the page fills in afterwards still comes from here',
      () async {
    final geocoder = _Geocoder();
    final svc = _service(forecast: _Forecast(), geocoder: geocoder);

    expect(await svc.placeLabelFor(40.2, -111.6), 'Provo, UT');
    expect(geocoder.calls, 1);
  });

  // REGRESSION: return periods arrive native CMS and the forecast flows are
  // already converted. Dropping the conversion shrinks every threshold ~35× for
  // a CFS user, so nearly every river reads as a top-category flood.
  group('return periods are converted from CMS before classifying', () {
    // 640 CFS ≈ 18.1 CMS. A 2-year threshold of 30 CMS ≈ 1059 CFS.
    // Converted → below it → Normal. Unconverted → 640 > 30 → top category.
    test('a flow under the converted 2-year threshold is Normal', () async {
      final svc = _service(
        forecast: _Forecast(
          returnPeriods: const {2: 30.0, 5: 60.0, 10: 90.0, 25: 150.0},
        ),
        geocoder: _Geocoder(),
      );

      final result = await svc.buildOutlook([_fav('1')]);

      expect(result.rows.single.categoryIndex, 0,
          reason: 'without the CMS→CFS conversion 640 clears a 30 "CFS" '
              'threshold and every river floods');
      expect(result.rows.single.category, 'Normal');
    });

    // The other direction, so the guard cannot be satisfied by a classifier
    // hardcoded to Normal.
    test('a flow above the converted 2-year threshold is not Normal', () async {
      final svc = _service(
        // 5 CMS ≈ 177 CFS, under the 640 CFS fixture flow.
        forecast: _Forecast(
          returnPeriods: const {2: 5.0, 5: 8.0, 10: 12.0, 25: 20.0},
        ),
        geocoder: _Geocoder(),
      );

      final result = await svc.buildOutlook([_fav('1')]);

      expect(result.rows.single.categoryIndex, greaterThan(0));
      expect(result.rows.single.category, isNot('Normal'));
    });
  });

  // REGRESSION: this is ADR 0010 itself. N favourites × loadCompleteReachData
  // in sequence is the 3-5 minute load that opened the whole workstream.
  test('every favourite is loaded concurrently, not one after another',
      () async {
    final forecast = _Forecast(delay: const Duration(milliseconds: 60));
    final svc = _service(forecast: forecast, geocoder: _Geocoder());

    final sw = Stopwatch()..start();
    await svc.buildOutlook([
      _fav('1'),
      _fav('2', order: 1),
      _fav('3', order: 2),
      _fav('4', order: 3),
    ]);
    sw.stop();

    expect(forecast.maxConcurrent, greaterThan(1),
        reason: 'a serial loop never has two loads in flight — this is the '
            'assertion that dies, the elapsed time below is corroboration');
    expect(sw.elapsedMilliseconds, lessThan(4 * 60),
        reason: 'four 60 ms loads run in sequence take ≥240 ms');
  });

  group('failures are reported, not silently dropped', () {
    // REGRESSION: every row failing used to yield an empty list, which the page
    // rendered as "no forecast is available" — a dead end with no Retry, from
    // the most ordinary failure there is.
    test('a total outage is distinguishable from an empty week', () async {
      final svc = _service(
        forecast: _Forecast(failFor: {'1', '2'}),
        geocoder: _Geocoder(),
      );

      final result = await svc.buildOutlook([_fav('1'), _fav('2', order: 1)]);

      expect(result.rows, isEmpty);
      expect(result.isTotalFailure, isTrue);
      expect(result.failedNames, hasLength(2),
          reason: 'the page names what failed; it cannot without these');
    });

    test('one bad reach does not blank the others', () async {
      final svc = _service(
        forecast: _Forecast(failFor: {'2'}),
        geocoder: _Geocoder(),
      );

      final result = await svc.buildOutlook([
        _fav('1'),
        _fav('2', order: 1),
        _fav('3', order: 2),
      ]);

      expect(result.rows, hasLength(2));
      expect(result.isTotalFailure, isFalse,
          reason: 'partial failure must still render what loaded');
      expect(result.failedNames, hasLength(1));
    });

    test('no favourites is an empty week, not a failure', () async {
      final svc = _service(forecast: _Forecast(), geocoder: _Geocoder());

      final result = await svc.buildOutlook([]);

      expect(result.rows, isEmpty);
      expect(result.isTotalFailure, isFalse,
          reason: 'nothing failed — showing an error here would be a lie');
    });
  });

  // The GEOGLOWS branch had NO coverage: `_Repo.read` returned null and no
  // fixture built a GEOGLOWS favourite, so it was never entered.
  group('the GEOGLOWS branch', () {
    test('reads through the cache, never as a forced refresh', () async {
      final repo = _Repo(forecast: _geoglowsForecast());
      final svc = _service(
          forecast: _Forecast(), geocoder: _Geocoder(), repo: repo);

      final result = await svc.buildOutlook([_geoFav('760021642')]);

      expect(result.rows, hasLength(1));
      expect(repo.reads, hasLength(1));
      expect(repo.refreshes, isEmpty,
          reason: 'refresh() bypasses the cache the sheet just warmed and '
              're-runs the ~20 s GEOGLOWS proxy — the rule every other '
              'surface is already held to');
    });

    // Class (h) at this surface, stated by a comment and never asserted:
    // GEOGLOWS values are converted at decode, so applying a CMS→CFS
    // conversion again here would multiply thresholds by 35 and flatten every
    // GEOGLOWS river to Normal.
    test('return periods are used as-is, not converted a second time',
        () async {
      final repo = _Repo(
        // 1000 sits above the 2-year threshold of 500 — an elevated river.
        forecast: _geoglowsForecast(
            returnPeriods: const {2: 500, 5: 800, 10: 1200, 25: 2000}),
      );
      final svc = _service(
          forecast: _Forecast(), geocoder: _Geocoder(), repo: repo);

      final result = await svc.buildOutlook([_geoFav('760021642')]);

      expect(result.rows.single.categoryIndex, greaterThan(0),
          reason: 'converting again turns 500 into ~17,657 and every GEOGLOWS '
              'river reads Normal');
      expect(result.rows.single.unit, 'ft³/s');
    });

    test('a repository that yields nothing is an empty week, not a failure',
        () async {
      final svc = _service(forecast: _Forecast(), geocoder: _Geocoder());

      final result = await svc.buildOutlook([_geoFav('760021642')]);

      expect(result.rows, isEmpty);
      expect(result.isTotalFailure, isFalse,
          reason: 'read() returned null without throwing — nothing failed');
    });

    test('NWM and GEOGLOWS favourites build side by side', () async {
      final repo = _Repo(forecast: _geoglowsForecast());
      final svc = _service(
          forecast: _Forecast(), geocoder: _Geocoder(), repo: repo);

      final result = await svc.buildOutlook([
        _fav('1'),
        _geoFav('760021642', order: 1),
      ]);

      expect(result.rows, hasLength(2));
      expect(result.rows.map((r) => r.source).toSet(),
          {ForecastSource.nwm, ForecastSource.geoglows});
    });
  });

  // The row must carry its own coordinate. The page used to match rows back to
  // favourites by reachId alone and, on no match, fall back to an arbitrary
  // favourite — labelling one river with another river's city.
  test('rows carry the coordinate their label will be resolved from', () async {
    final svc = _service(forecast: _Forecast(), geocoder: _Geocoder());

    final result = await svc.buildOutlook([_fav('1')]);

    expect(result.rows.single.latitude, 40.2);
    expect(result.rows.single.longitude, -111.6);
  });
}
