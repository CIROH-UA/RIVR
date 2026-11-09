// test/services/4_infrastructure/river_data/one_product_per_entry_test.dart
//
// Backlog item 3: "the app can cache an EMPTY forecast over a full one."
//
// NOAA's `?series=` is a filter it honours only sometimes. ⏱ MEASURED
// 2026-11-09 16:56 UTC on 10 CONUS reaches taken from this repo's own tests
// and docs (6 more returned 503 and are discarded): `?series=medium_range`
// comes back HTTP 200 with ALL FIVE sections `{}`, 10 of 10. The app then
// refetches the UNFILTERED body, which for those same reaches carries
// `analysisAssimilation` 47 points and `shortRange` 18 points with medium and
// long range empty, 10 of 10.
//
// That whole unfiltered body used to be handed back to the caller. The caller
// is a cache keyed by PRODUCT, so a medium-range read stored a full copy of
// SHORT range inside the medium-range entry, on medium range's 6-hour window.
//
// Two harms from the one leak:
//
//   * `ReachDataProvider._mergeForecastData` lets whichever section load
//     lands LAST win, so the hourly chart and the gauge could be driven by
//     that copy instead of by the dedicated short-range entry on its 1-hour
//     window, and differ between two opens of the same page.
//   * It defeated the empty-section window. The source gives an answer with
//     no readable points a short retry window instead of its product's full
//     one, and asks that of the payload as a whole — on purpose, because
//     naming a section per product would duplicate the decoder's mapping. A
//     smuggled short range answered the question, so an empty medium range
//     was held for six hours as a confirmed current value.
//
// The bodies below are fixtures. They are shaped like what was measured, but
// nothing here asserts on live upstream: NOAA's medium and long range were
// empty for every reach that answered on the day this was written and carried
// data earlier the same day, so a test that read upstream would go green at
// 10am and red at midnight for no reason.

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/4_infrastructure/api/noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_forecast_payload.dart';
import 'package:rivr/services/4_infrastructure/river_data/river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';
import 'package:rivr/services/4_infrastructure/shared/flow_unit_preference_service.dart';

import '_phase2_fakes.dart';

const _reachId = '23021904';

RiverDataKey _keyFor(ForecastProduct product) => RiverDataKey(
      source: ForecastSource.nwm,
      reachId: _reachId,
      product: product,
    );

Map<String, dynamic> _reachBlock(List<String> streamflow) => {
      'reachId': _reachId,
      'name': 'Provo River',
      'latitude': 40.3,
      'longitude': -111.6,
      'streamflow': streamflow,
    };

Map<String, dynamic> _deterministic(String referenceTime, double flow) => {
      'series': {
        'referenceTime': referenceTime,
        'units': 'ft³/s',
        'data': [
          {'validTime': '2026-11-09T13:00:00Z', 'flow': flow},
        ],
      },
    };

/// What `?series=<anything>` returns when the window is shut: 200, and every
/// section `{}`. Measured 10 of 10.
String _filteredAllEmpty() => jsonEncode({
      'reach': _reachBlock(['short_range']),
      'analysisAssimilation': <String, dynamic>{},
      'shortRange': <String, dynamic>{},
      'mediumRange': <String, dynamic>{},
      'longRange': <String, dynamic>{},
      'mediumRangeBlend': <String, dynamic>{},
    });

/// The UNFILTERED body for the same reaches at the same moment: short range
/// and analysis assimilation populated, the other three empty. This is the
/// body the leak was smuggling.
String _unfilteredShortOnly() => jsonEncode({
      'reach': _reachBlock(['short_range']),
      'analysisAssimilation': _deterministic('2026-11-09T12:00:00Z', 120.0),
      'shortRange': _deterministic('2026-11-09T12:00:00Z', 118.0),
      'mediumRange': <String, dynamic>{},
      'longRange': <String, dynamic>{},
      'mediumRangeBlend': <String, dynamic>{},
    });

/// The unfiltered body on a day medium range IS served — what the fallback
/// exists for, and the control that the fix did not throw the answer away
/// along with the siblings.
String _unfilteredWithMedium() => jsonEncode({
      'reach': _reachBlock(['short_range', 'medium_range']),
      'analysisAssimilation': _deterministic('2026-11-09T12:00:00Z', 120.0),
      'shortRange': _deterministic('2026-11-09T12:00:00Z', 118.0),
      'mediumRange': {
        'mean': {
          'referenceTime': '2026-11-09T06:00:00Z',
          'units': 'ft³/s',
          'data': [
            {'validTime': '2026-11-10T00:00:00Z', 'flow': 200.0},
            {'validTime': '2026-11-11T00:00:00Z', 'flow': 210.0},
          ],
        },
      },
      'longRange': <String, dynamic>{},
      'mediumRangeBlend': <String, dynamic>{},
    });

void main() {
  late FlowUnitPreferenceService unit;
  late MemoryCache cache;
  late RiverDataRepository repo;
  late NoaaApiService api;
  late int httpCalls;
  late List<String> urls;
  late DateTime clock;

  /// `?series=` requests get [filtered]; the unfiltered request gets
  /// [unfiltered]. Told apart by the URL, never by call order.
  void arrange({required String filtered, required String unfiltered}) {
    unit = FlowUnitPreferenceService()..setFlowUnit('CFS');
    httpCalls = 0;
    urls = [];
    clock = DateTime.utc(2026, 11, 9, 16, 0);
    final client = MockClient((req) async {
      httpCalls++;
      urls.add(req.url.toString());
      final isFiltered = req.url.queryParameters.containsKey('series');
      return http.Response(isFiltered ? filtered : unfiltered, 200);
    });
    api = NoaaApiService(client: client, unitService: unit);
    cache = MemoryCache();
    repo = RiverDataRepository(
      cache: cache,
      clock: () => clock,
      registry: SourceRegistry([
        NwmDataSource(
          api: api,
          forecastService: UnusedForecastService(),
          unitService: unit,
          geocoder: NullGeocoder(),
          clock: () => clock,
        )
      ]),
    );
  }

  /// How long the stored answer is good for, in minutes.
  int windowMinutes(entry) =>
      entry.window.validUntil.difference(entry.window.fetchedAt).inMinutes;

  group('a product answers with its own section only', () {
    test('a medium-range fetch does not return short range', () async {
      arrange(filtered: _filteredAllEmpty(), unfiltered: _unfilteredShortOnly());

      final payload = await api.fetchForecast(_reachId, 'medium_range');

      expect(payload['shortRange'], isNull,
          reason: 'the unfiltered fallback body carries every section; only '
              'the requested one may reach the caller, because the caller '
              'stores it under the requested product');
      expect(payload['longRange'], isNull);
      expect(payload['analysisAssimilation'], isNull,
          reason: 'no product maps to this section, so it is nobody\'s '
              'answer and must not ride along in everybody\'s entry');
      expect(payload['mediumRangeBlend'], isNull);
      expect(payload['reach'], isNotNull,
          reason: 'the reach block is not a forecast section and every '
              'consumer of a forecast payload reads the river name from it');
    });

    test('the requested section is present even when upstream omits it',
        () async {
      // The key must exist so that "asked and got nothing" stays
      // distinguishable from "never asked". Driven from a body that omits
      // `mediumRange` ENTIRELY: an earlier version of this test used a
      // fixture that already carried `'mediumRange': {}`, so it passed with
      // the line that adds the key deleted. An independent review caught
      // that, and it is the same vacuous-guard shape this project keeps
      // finding.
      arrange(
        filtered: _filteredAllEmpty(),
        unfiltered: jsonEncode({
          'reach': _reachBlock(['short_range']),
          'shortRange': _deterministic('2026-11-09T12:00:00Z', 118.0),
        }),
      );

      final payload = await api.fetchForecast(_reachId, 'medium_range');

      expect(payload.containsKey('mediumRange'), isTrue);
      expect(payload['mediumRange'], isEmpty);
    });

    test('a short-range fetch does not return medium or long range', () async {
      arrange(
        filtered: _unfilteredWithMedium(),
        unfiltered: _unfilteredWithMedium(),
      );

      final payload = await api.fetchForecast(_reachId, 'short_range');

      expect(payload['mediumRange'], isNull);
      expect(payload['longRange'], isNull);
      expect((payload['shortRange'] as Map)['series'], isNotNull);
      expect(urls, hasLength(1),
          reason: 'short range is populated in the filtered answer here, so '
              'nothing falls back — proving the trim fires on the direct '
              'path too, not only inside the fallback');
    });

    test('one unfiltered body serves two products without being poisoned',
        () async {
      // The unfiltered response is cached whole for 30 seconds so that a
      // second product's fallback shares the one request. That sharing only
      // survives if the trim COPIES; trimming the cached map in place would
      // let the first faller-back strip the sections the second one needs.
      // An independent review mutated exactly that and the whole suite
      // stayed green, so this is the missing guard.
      arrange(filtered: _filteredAllEmpty(), unfiltered: _unfilteredShortOnly());

      final medium = await api.fetchForecast(_reachId, 'medium_range');
      final short = await api.fetchForecast(_reachId, 'short_range');

      expect(medium['mediumRange'], isEmpty);
      expect((short['shortRange'] as Map)['series'], isNotNull,
          reason: 'the second product must still find its own section in the '
              'shared body after the first product trimmed its copy');
      expect(urls.where((u) => !u.contains('series=')), hasLength(1),
          reason: 'and the body is fetched once, which is what the '
              '30-second cache is for');
    });
  });

  group('the fallback still does its job', () {
    test('an unfiltered body that DOES carry medium range is served', () async {
      arrange(
        filtered: _filteredAllEmpty(),
        unfiltered: _unfilteredWithMedium(),
      );

      final entry = await repo.read(_keyFor(ForecastProduct.mediumRange));
      final decoded = NwmForecastPayload.decode(entry!, unit)!;

      expect(urls, hasLength(2),
          reason: 'the filtered call came back empty, so the fallback fired');
      expect(urls.first, contains('series=medium_range'));
      expect(urls.last, isNot(contains('series=')));
      expect(decoded.mediumRange['mean']?.data, hasLength(2),
          reason: 'this is the whole reason the unfiltered fallback exists; '
              'trimming must not throw the answer away with the siblings');
      expect(decoded.shortRange?.data.isEmpty ?? true, isTrue,
          reason: 'and the entry still carries nothing but its own product');
      // `startsWith`, because the unit converter round-trips the timestamp
      // and returns `...06:00:00.000Z`. The run IDENTITY is the point: 06Z is
      // medium range's own 6-hourly run, not short range's 12Z hourly one.
      expect(entry.runId, startsWith('2026-11-09T06:00:00'));
      expect(windowMinutes(entry), greaterThan(60),
          reason: 'a populated answer gets its publish-aligned window, not '
              'the short empty-section retry');
    });
  });

  group('an empty section is a short answer, not an app error', () {
    test('it is held for minutes, not for its publish window', () async {
      arrange(filtered: _filteredAllEmpty(), unfiltered: _unfilteredShortOnly());

      final entry = await repo.read(_keyFor(ForecastProduct.mediumRange));

      expect(entry, isNotNull,
          reason: 'it IS cached. Refusing to cache it made every read refetch '
              'and turned one page open into a climbing count of calls');
      expect(windowMinutes(entry), NwmDataSource.emptySectionRetry.inMinutes,
          reason: 'medium range would otherwise be held to the next 6-hour '
              'cycle, so one unlucky request meant an empty 10-day panel all '
              'morning with no further attempt');
      expect(NwmForecastPayload.decode(entry!, unit)!.mediumRange, isEmpty,
          reason: 'and it decodes to nothing, which is what drives the panel '
              'to SectionLoadState.empty — orange, "temporarily '
              'unavailable", rather than red "something went wrong"');
    });

    test('the app does not claim its own data is stale', () async {
      arrange(filtered: _filteredAllEmpty(), unfiltered: _unfilteredShortOnly());

      await repo.read(_keyFor(ForecastProduct.mediumRange));

      expect(repo.outOfSync.value, isFalse,
          reason: 'outOfSync means "we served a value we cannot vouch for". '
              'An accurate report that upstream has nothing is not that, and '
              'raising it put the app-wide banner over the favourites page '
              'for half an hour on every CONUS river, every time');
    });

    test('a later read asks again once the short window has passed', () async {
      arrange(filtered: _filteredAllEmpty(), unfiltered: _unfilteredShortOnly());
      final key = _keyFor(ForecastProduct.mediumRange);

      await repo.read(key);
      final afterFirst = httpCalls;
      await repo.read(key);
      expect(httpCalls, afterFirst,
          reason: 'inside the window it is served from cache — this is the '
              'repeat that was costing a call on every read');

      clock = clock.add(NwmDataSource.emptySectionRetry * 2);
      await repo.read(key);
      // The expired answer is served instantly and refreshed BEHIND the
      // reader (stale-while-revalidate), so the call lands on the event
      // queue rather than inside this await. Pumping is the assertion, not a
      // workaround: a user looking at a stale empty panel must not be made
      // to wait on the network before the page can draw.
      await pumpEventQueue();

      expect(httpCalls, greaterThan(afterFirst),
          reason: 'and once it expires we ask again, which is the half of '
              'the original fix worth keeping');
    });

    test('a sibling section carrying data does not rescue it', () async {
      // The point of the whole item. Short range is fully populated in the
      // unfiltered body, so the empty-section check would have been satisfied
      // by it had it ever reached the medium-range payload.
      arrange(filtered: _filteredAllEmpty(), unfiltered: _unfilteredShortOnly());

      final medium = await repo.read(_keyFor(ForecastProduct.mediumRange));
      final long = await repo.read(_keyFor(ForecastProduct.longRange));
      final short = await repo.read(_keyFor(ForecastProduct.shortRange));

      expect(windowMinutes(medium), NwmDataSource.emptySectionRetry.inMinutes);
      expect(windowMinutes(long), NwmDataSource.emptySectionRetry.inMinutes);
      expect(NwmForecastPayload.decode(short!, unit)!.shortRange?.data,
          hasLength(1),
          reason: 'the same body, asked the right question, still answers');
      expect(windowMinutes(short), greaterThan(NwmDataSource.emptySectionRetry.inMinutes),
          reason: 'and a populated answer keeps its real window');
    });

    test('shortRange gets the short window too, not just medium and long',
        () async {
      // An independent review found this call site pinned by NOTHING:
      // deleting the check for the shortRange product alone left all 1,486
      // tests green. shortRange is the product `loadAllData` AWAITS as the
      // page's overview, so an empty one held for its full hour as a
      // confirmed value is the worst of the four, not the least.
      arrange(
        filtered: _filteredAllEmpty(),
        unfiltered: _filteredAllEmpty(),
      );

      final entry = await repo.read(_keyFor(ForecastProduct.shortRange));

      expect(windowMinutes(entry), NwmDataSource.emptySectionRetry.inMinutes);
      expect(NwmForecastPayload.decode(entry!, unit)!.shortRange?.data.isEmpty ?? true,
          isTrue);
    });

    test('currentFlow gets it as well, and keeps the river readable', () async {
      arrange(
        filtered: _filteredAllEmpty(),
        unfiltered: _filteredAllEmpty(),
      );

      final entry = await repo.read(_keyFor(ForecastProduct.currentFlow));

      expect(entry, isNotNull,
          reason: 'this one matters beyond its own panel: '
              'FavoritesProvider reads the name, the flow and the thresholds '
              'in one Future.wait inside one try, so a THROW here discarded '
              "the river's name and its flood thresholds as well");
      expect(windowMinutes(entry), NwmDataSource.emptySectionRetry.inMinutes);
    });
  });
}
