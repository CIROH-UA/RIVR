// test/services/4_infrastructure/river_data/one_product_per_entry_test.dart
//
// Backlog item 3: "the app can cache an EMPTY forecast over a full one."
//
// NOAA's `?series=` is a filter it honours only sometimes. When the filtered
// call comes back with the requested section empty, this app refetches the
// UNFILTERED body — every section in one response — and used to hand that
// whole body back to the caller. The caller is a cache keyed by PRODUCT, so a
// `mediumRange` read that fell back stored a full copy of SHORT range inside
// the medium-range entry, stamped with medium range's 6-hour window.
//
// Two separate harms, both from that one leak:
//
//   * `ReachDataProvider._mergeForecastData` lets whichever section load
//     lands LAST win. So the hourly chart and the gauge could be driven by
//     the stale smuggled copy instead of by the dedicated short-range entry
//     on its 1-hour window, differing between two opens of the same page.
//   * It defeated the empty-section guard added for item 4.
//     `NwmDataSource._requireUsableSeries` refuses to store a payload with
//     nothing readable in it, and asks that of the payload as a whole — on
//     purpose, because naming a section per product would duplicate the
//     decoder's mapping. A smuggled short range answered the question, so an
//     empty medium range was stored as a CONFIRMED, current value and held
//     for six hours with no indicator. Under ADR 0011 Phase 7, silence is a
//     positive claim that what is on screen is current.
//
// The bodies here are fixtures, never assertions about live upstream: NOAA's
// medium and long range were `{}` for 16 of 16 reaches when this was written
// (2026-11-09) and carried data earlier the same day. A test that asserted on
// upstream would go green at 10am and red at midnight for no reason.

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

Map<String, dynamic> _series(String referenceTime, double flow) => {
      'series': {
        'referenceTime': referenceTime,
        'units': 'ft³/s',
        'data': [
          {'validTime': '2026-11-09T13:00:00Z', 'flow': flow},
        ],
      },
    };

/// The EXACT shape measured from api.water.noaa.gov on 2026-11-09: HTTP 200,
/// short range and analysis assimilation populated, the other three `{}`.
String _emptyMediumBody() => jsonEncode({
      'reach': {
        'reachId': _reachId,
        'name': 'Provo River',
        'latitude': 40.3,
        'longitude': -111.6,
        'streamflow': ['short_range'],
      },
      'analysisAssimilation': _series('2026-11-09T12:00:00Z', 120.0),
      'shortRange': _series('2026-11-09T12:00:00Z', 118.0),
      'mediumRange': <String, dynamic>{},
      'longRange': <String, dynamic>{},
      'mediumRangeBlend': <String, dynamic>{},
    });

/// The same body with medium range POPULATED — what the fallback exists for.
/// Upstream drops `?series=medium_range` on the floor but serves the section
/// in the unfiltered body, which is a real thing it does and the only reason
/// the fallback is worth having.
String _populatedMediumBody() => jsonEncode({
      'reach': {
        'reachId': _reachId,
        'name': 'Provo River',
        'latitude': 40.3,
        'longitude': -111.6,
        'streamflow': ['short_range', 'medium_range'],
      },
      'analysisAssimilation': _series('2026-11-09T12:00:00Z', 120.0),
      'shortRange': _series('2026-11-09T12:00:00Z', 118.0),
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

  /// Every request answers with [body], unless [unfilteredBody] is given —
  /// then the `?series=` call gets [body] and the unfiltered call gets
  /// [unfilteredBody], which is the real upstream behaviour the fallback
  /// exists for: the filter is dropped and the section is served only in the
  /// full response. Keyed off the URL, never off call order.
  void arrange(String body, {String? unfilteredBody}) {
    unit = FlowUnitPreferenceService()..setFlowUnit('CFS');
    httpCalls = 0;
    urls = [];
    final client = MockClient((req) async {
      httpCalls++;
      final url = req.url.toString();
      urls.add(url);
      final filtered = req.url.queryParameters.containsKey('series');
      return http.Response(
        !filtered && unfilteredBody != null ? unfilteredBody : body,
        200,
      );
    });
    api = NoaaApiService(client: client, unitService: unit);
    cache = MemoryCache();
    repo = RiverDataRepository(
      cache: cache,
      registry: SourceRegistry([
        NwmDataSource(
          api: api,
          forecastService: UnusedForecastService(),
          unitService: unit,
          geocoder: NullGeocoder(),
        )
      ]),
    );
  }

  group('a product answers with its own section only', () {
    test('a medium-range fetch does not return short range', () async {
      arrange(_emptyMediumBody());

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
      expect(payload.containsKey('mediumRange'), isTrue,
          reason: '"asked and got nothing" must stay distinguishable from '
              '"never asked"');
      expect(payload['reach'], isNotNull,
          reason: 'the reach block is not a forecast section and every '
              'consumer of a forecast payload reads the river name from it');
    });

    test('a short-range fetch does not return medium or long range', () async {
      arrange(_populatedMediumBody());

      final payload = await api.fetchForecast(_reachId, 'short_range');

      expect(payload['mediumRange'], isNull);
      expect(payload['longRange'], isNull);
      expect((payload['shortRange'] as Map)['series'], isNotNull);
      expect(urls, hasLength(1),
          reason: 'short range is populated here, so there is nothing to '
              'fall back for — proving the trim is not firing on the '
              'unfiltered path only');
    });
  });

  group('the fallback still does its job', () {
    test('an unfiltered body that DOES carry medium range is served', () async {
      arrange(_emptyMediumBody(), unfilteredBody: _populatedMediumBody());

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
      // and hands back `...06:00:00.000Z`. The run IDENTITY is the point:
      // 06Z is medium range's own 6-hourly run, not short range's 12Z hourly
      // one, which an earlier first-found version of `_runIdOf` used to
      // stamp on these entries.
      expect(entry.runId, startsWith('2026-11-09T06:00:00'),
          reason: "medium range's own run, not short range's hourly one");
    });
  });

  group('an empty section is a failure, not a current value', () {
    test('it is not stored, and the sync banner is raised', () async {
      arrange(_emptyMediumBody());
      final key = _keyFor(ForecastProduct.mediumRange);

      await expectLater(repo.read(key), throwsA(isA<EmptyForecastSection>()));

      expect(cache.entries.containsKey(key.storageKey), isFalse,
          reason: 'storing it gives it a 6-hour window and a confirmed '
              'judgement, which is a positive claim that an empty 10-day '
              'panel is current');
      expect(repo.outOfSync.value, isTrue,
          reason: 'the server already calls this response a failure and '
              'retries it with backoff; the device used to call it current');
    });

    test('every later read tries again instead of holding the empty answer',
        () async {
      arrange(_emptyMediumBody());
      final key = _keyFor(ForecastProduct.mediumRange);

      // Deliberately counts fetches rather than measuring the window: the
      // earlier version of this assertion compared `validUntil - fetchedAt`
      // against an hour, which depends on where in the 6-hour NWM cycle the
      // clock happens to sit and would pass by accident near a boundary.
      for (var i = 0; i < 3; i++) {
        await expectLater(repo.read(key), throwsA(isA<EmptyForecastSection>()));
      }

      // Four, not six: the first read pays for both the filtered call and
      // the unfiltered fallback, and the next two reuse the unfiltered body
      // from its own 30-second in-memory cache. What matters is that the
      // number keeps CLIMBING — before this, one empty answer meant an empty
      // 10-day panel for up to six hours with no further attempt at all.
      expect(httpCalls, 4,
          reason: 'nothing cached means nothing held, so every read tries '
              'again — sharing the unfiltered body for 30 seconds, which is '
              'what that short-lived cache is for');
    });

    test('a sibling section carrying data does not rescue it', () async {
      // The point of the whole item. Short range is fully populated in this
      // body, so the empty-section guard would have been satisfied by it had
      // it ever reached the payload.
      arrange(_emptyMediumBody());

      await expectLater(repo.read(_keyFor(ForecastProduct.longRange)),
          throwsA(isA<EmptyForecastSection>()));
      final short = await repo.read(_keyFor(ForecastProduct.shortRange));

      expect(NwmForecastPayload.decode(short!, unit)!.shortRange?.data,
          hasLength(1),
          reason: 'the same body, asked the right question, still answers');
    });
  });
}
