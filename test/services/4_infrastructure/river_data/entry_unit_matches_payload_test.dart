// PHASE 2 BASELINE — MUST FAIL against HEAD b2aa2ac.
//
// Defect #4 (audit D2/D3/D4). ONE invariant, broken three ways:
//
//     entry.unit must describe the payload that is actually stored.
//
// `NwmDataSource.fetch` (lib/services/4_infrastructure/river_data/nwm_data_source.dart:143)
// reads `_unitService.currentFlowUnit` and tags the entry with it, while the
// conversion that produced the payload happens somewhere else at some other
// moment inside `NoaaApiService`. Nothing reconciles the two, and
// `CurrentFlowPayload.decode` (narrow_nwm_payloads.dart:55-57) trusts
// `entry.unit` alone.
//
//   D3  the tag is captured BEFORE the await; `_convertForecastResponse`
//       reads the preference again AFTER it. A unit toggle in that window
//       (favorites_page.dart:871-893 flips it without cancelling in-flight
//       reads) tags CMS data as CFS -> decode re-converts -> 35.3x too LOW ->
//       classified against correct CMS thresholds -> EVERY RIVER READS
//       NORMAL. That is the shape of the 2026-08-30 card defect.
//
//   D2  CORRECTED 2026-11-09 by this very test. I first reported D2 as a
//       35.3x-too-HIGH error, having measured only the API layer in
//       isolation. Running the FULL chain disproved that: `_convertSingleSeries`
//       (noaa_api_service.dart:658) and `_parseForecastSection`
//       (reach_data_dto.dart:402) use the SAME `ForecastSeriesDto.fromJson`,
//       so any input that defeats the converter also defeats the decoder, and
//       the entry decodes to null rather than to a mislabelled number.
//       The real defect is narrower and still real: ONE malformed point
//       (`"flow": null`, which ForecastPointDto turns into a cast error at
//       reach_data_dto.dart:225) discards the ENTIRE series including the
//       good points, the reach shows "No data", and the entry is STILL cached
//       as a success with a full window and `outOfSync` false.
//
//   D4  `_unfilteredCache` (noaa_api_service.dart:22-23, 355-379) is keyed by
//       reachId ALONE, 30s TTL, and stores the ALREADY-CONVERTED payload with
//       no record of what it was converted to.
//
// Every assertion below is on the DECODED value — what the card and the
// gauge actually display — not on any internal field, and every response body
// is supplied by a MockClient, so nothing here depends on upstream.

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/api/noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/narrow_nwm_payloads.dart';
import 'package:rivr/services/4_infrastructure/river_data/river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';
import 'package:rivr/services/4_infrastructure/shared/flow_unit_preference_service.dart';

import '_phase2_fakes.dart';

/// 1000 ft3/s, which is 28.3168 m3/s. Chosen so a missed or doubled
/// conversion is unmistakable: the wrong answers are 0.80 and 35315.
const double kFlowCfs = 1000.0;
const double kFlowCms = 28.316819907857067;

const _currentFlowKey = RiverDataKey(
  source: ForecastSource.nwm,
  reachId: '10376605',
  product: ForecastProduct.currentFlow,
);

/// A run identity that is always FRESH, relative to now.
///
/// It was the literal `2026-11-09T12:00:00Z`. That was fine on the day it was
/// written and became a time bomb the next morning: `currentFlow`'s run-age
/// cap is 16 hours, so once real time moved past that the repository
/// correctly judged the entry too old, raised `outOfSync`, and D2b's
/// assertion that the banner stays quiet started failing. CI caught it about
/// nine hours after it was written and the suite had been green locally all
/// evening.
///
/// This is the same defect class as backlog item 9, which was a wall-clock
/// assertion in the repository tests, and I introduced a fresh one while
/// fixing item 3. A fixture that encodes "now" as a constant has an expiry
/// date nobody writes down.
String freshRunId() => DateTime.now()
    .toUtc()
    .subtract(const Duration(hours: 1))
    .toIso8601String();

String body({List<Map<String, dynamic>>? points, String units = 'ft³/s'}) =>
    jsonEncode({
      'reach': {
        'reachId': '10376605',
        'name': 'Provo River',
        'latitude': 40.3,
        'longitude': -111.6,
        'streamflow': ['short_range'],
      },
      'shortRange': {
        'series': {
          'referenceTime': freshRunId(),
          'units': units,
          'data': points ??
              [
                {
                  'validTime': DateTime.now().toUtc().toIso8601String(),
                  'flow': kFlowCfs,
                }
              ],
        },
      },
      'mediumRange': <String, dynamic>{},
      'longRange': <String, dynamic>{},
      'mediumRangeBlend': <String, dynamic>{},
      'analysisAssimilation': <String, dynamic>{},
    });

RiverDataEntry asEntry(RiverDataKey key, SourceFetchResult r) => RiverDataEntry(
      key: key,
      window: FreshnessWindow(
        fetchedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
      unit: r.unit,
      runId: r.runId,
      payload: r.payload,
    );

NwmDataSource sourceOver(
  http.Client client,
  FlowUnitPreferenceService unit,
) =>
    NwmDataSource(
      api: NoaaApiService(client: client, unitService: unit),
      forecastService: UnusedForecastService(),
      unitService: unit,
      geocoder: NullGeocoder(),
    );

void main() {
  test('control: with nothing racing, a CMS reader sees 28.32', () async {
    final unit = FlowUnitPreferenceService()..setFlowUnit('CMS');
    final src = sourceOver(MockClient((_) async => http.Response(body(), 200)),
        unit);
    final decoded = CurrentFlowPayload.decode(
        asEntry(_currentFlowKey, await src.fetch(_currentFlowKey)), unit);
    // ignore: avoid_print
    print('control decoded=$decoded (expect $kFlowCms)');
    expect(decoded, closeTo(kFlowCms, 0.001));
  });

  test('D3: a unit toggle landing DURING the fetch must not change the number '
      'the reader sees', () async {
    final unit = FlowUnitPreferenceService()..setFlowUnit('CFS');
    final client = MockClient((_) async {
      // The user taps ft3/s -> m3/s while the request is in flight.
      unit.setFlowUnit('CMS');
      return http.Response(body(), 200);
    });
    final result = await sourceOver(client, unit).fetch(_currentFlowKey);
    final decoded =
        CurrentFlowPayload.decode(asEntry(_currentFlowKey, result), unit);
    // ignore: avoid_print
    print('D3 entry.unit=${result.unit} decoded=$decoded (expect $kFlowCms; '
        '0.80 means the value was converted twice)');
    expect(decoded, closeTo(kFlowCms, 0.001),
        reason: '35.3x too LOW classifies every river as Normal against '
            'correct CMS thresholds — the 2026-08-30 defect, as a race');
  });

  test('D2: one unparseable point must not discard the good points in the '
      'same series', () async {
    final unit = FlowUnitPreferenceService()..setFlowUnit('CMS');
    final client = MockClient((_) async => http.Response(
        body(points: [
          {
            'validTime': DateTime.now().toUtc().toIso8601String(),
            'flow': kFlowCfs,
          },
          // NOAA sends a gap. ForecastPointDto does `(json['flow'] as num)`
          // (reach_data_dto.dart:225), which throws on null.
          {
            'validTime': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .toIso8601String(),
            'flow': null,
          },
        ]),
        200));
    final result = await sourceOver(client, unit).fetch(_currentFlowKey);
    final decoded =
        CurrentFlowPayload.decode(asEntry(_currentFlowKey, result), unit);
    // ignore: avoid_print
    print('D2 entry.unit=${result.unit} decoded=$decoded '
        '(expect $kFlowCms from the GOOD point; null = whole series discarded)');
    expect(decoded, closeTo(kFlowCms, 0.001),
        reason: 'the reach has a perfectly good current-flow value and shows '
            '"No data"; a bad point should be skipped, not fatal to the series');
  });

  test('D2b: a series that could not be read must not be cached as a '
      'confirmed success', () async {
    final unit = FlowUnitPreferenceService()..setFlowUnit('CMS');
    final client = MockClient((_) async => http.Response(
        body(points: [
          {
            'validTime': DateTime.now().toUtc().toIso8601String(),
            'flow': null,
          },
        ]),
        200));
    final cache = MemoryCache();
    final repo = RiverDataRepository(
      cache: cache,
      registry: SourceRegistry([sourceOver(client, unit)]),
    );
    // An answer with nothing readable in it is held for MINUTES, not for the
    // product's publish window.
    //
    // This assertion has been round the houses twice and the history is
    // worth keeping. The baseline expected an entry back and then checked
    // the freshness claim, because an unreadable series was stored as an
    // ordinary success. It was then changed to expect a THROW, on the
    // reasoning that there is nothing to cache and nothing to vouch for —
    // and an independent review measured what that did on screen:
    // `ReachDataProvider` turns any exception from a section read into
    // `SectionLoadState.error`, which renders RED "Something went wrong …
    // Pull down to retry" for the normal case of upstream having no data.
    // Worse, `FavoritesProvider` reads name, flow and thresholds in one
    // `Future.wait` inside one `try`, so the throw took the river's NAME and
    // its FLOOD THRESHOLDS down with the flow.
    //
    // So the answer is cached, briefly. The honest half of the fix is the
    // WINDOW, not the refusal.
    final entry = await repo.read(_currentFlowKey);

    expect(entry, isNotNull,
        reason: 'refusing to cache it made every read refetch, and took the '
            "river's name and thresholds with it on the favourites path");
    expect(
      entry!.window.validUntil.difference(entry.window.fetchedAt).inMinutes,
      NwmDataSource.emptySectionRetry.inMinutes,
      reason: 'a payload whose only point has a null flow decodes to no '
          'series at all. Holding that for the product\'s full window is '
          'what made a reach show "No data" while the app claimed it was '
          'current, with no later read retrying',
    );
    expect(CurrentFlowPayload.decode(entry, unit), isNull,
        reason: 'and there is genuinely no number to show');
    expect(repo.outOfSync.value, isFalse,
        reason: 'outOfSync means "we served a value we cannot vouch for". '
            'Reporting accurately that upstream has nothing is not that, and '
            'raising it here lit the app-wide banner on every CONUS river');
  });

  test('D4: the 30-second unfiltered-fallback cache must not serve a payload '
      'in a different unit than the caller is tagged with', () async {
    final unit = FlowUnitPreferenceService()..setFlowUnit('CFS');
    final client = MockClient((req) async {
      // Filtered: structurally present, no data -> forces the fallback.
      if (req.url.queryParameters.containsKey('series')) {
        return http.Response(body(points: const []), 200);
      }
      return http.Response(body(), 200);
    });
    final src = sourceOver(client, unit);

    // First caller, preference CFS: populates _unfilteredCache[reachId].
    await src.fetch(_currentFlowKey);

    // The user flips the unit, then something reads again inside the 30s TTL.
    unit.setFlowUnit('CMS');
    final result = await src.fetch(_currentFlowKey);
    final decoded =
        CurrentFlowPayload.decode(asEntry(_currentFlowKey, result), unit);
    // ignore: avoid_print
    print('D4 entry.unit=${result.unit} decoded=$decoded (expect $kFlowCms; '
        '1000.0 means CFS bytes came back from the cache tagged CMS)');
    expect(decoded, closeTo(kFlowCms, 0.001),
        reason: 'the cache is keyed by reachId alone and stores converted '
            'values with no record of the unit');
  });
}
