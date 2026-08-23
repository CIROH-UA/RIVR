// test/ui/2_presentation/features/forecast/reach_forecast_page_test.dart
//
// Widget tests for the consolidated forecast page. Covers both source paths:
//  - GEOGLOWS: reads geoglowsForecast from the repository; no ReachDataProvider.
//  - NWM: reads the three narrow products from the repository (ADR 0011 Phase 1); a fake ReachDataProvider
//    stands in for the (separate) forecast-series load.

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/services/4_infrastructure/river_data/reach_summary_payload.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';
import 'package:rivr/ui/2_presentation/features/forecast/pages/reach_forecast_page.dart';

// ── Fakes ────────────────────────────────────────────────────────────────────

/// Identity unit service — tests provide values already in the display unit.
class _StubUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
  /// Real, not identity. With the identity stub a missing CMS→CFS conversion
  /// was invisible: review showed the category assertion passed either way.
  @override
  double convertFlow(double value, String from, String to) {
    if (from == to) return value;
    if (from == 'CMS' && to == 'CFS') return value * 35.3147;
    if (from == 'CFS' && to == 'CMS') return value / 35.3147;
    return value;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `CurrentFlowPayload.decode` delegates the extraction to IForecastService —
/// deliberately, so there is only one implementation of "what is the current
/// flow" (ADR 0011 decision 13). The page therefore needs one registered.
/// Injected so this test stops making live Mapbox calls — review measured two
/// real reverse-geocodes per run, making the suite depend on internet and on a
/// gitignored token.
class _FakeGeocoder implements IGeocodingService {
  _FakeGeocoder({this.delay});
  final Duration? delay;
  int calls = 0;
  @override
  Future<Map<String, String?>> reverseGeocode(double lat, double lon) async {
    calls++;
    if (delay != null) await Future<void>.delayed(delay!);
    return {'city': 'Testville', 'state': 'TS', 'country': 'US'};
  }
  @override
  Future<String?> placeLabel(double? lat, double? lon) async {
    calls++;
    if (delay != null) await Future<void>.delayed(delay!);
    return 'Testville, TS';
  }
}

class _StubForecastService implements IForecastService {
  @override
  double? getCurrentFlow(ForecastResponse forecast, {String? preferredType}) =>
      640.0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRepo implements IRiverDataRepository {
  _FakeRepo(this.entry, {this.byProduct = const {}, this.delay, this.failAll = false});
  final bool failAll;
  final Duration? delay;
  final RiverDataEntry? entry;

  /// Per-product payloads. The NWM page reads three narrow products now
  /// (ADR 0011 Phase 1) rather than one bundled `reachSummary`, so a single
  /// entry for every key would hand each read the wrong shape.
  final Map<ForecastProduct, Map<String, dynamic>> byProduct;

  /// Which products the page asked for. Review proved this was unguarded:
  /// reverting the page to the bundled `reachSummary` — reintroducing both the
  /// 156 KB fetch and the two-entry divergence — left the whole suite green.
  final List<ForecastProduct> requested = [];

  /// Tracked separately — see the sheet test: `refresh` bypasses the cache, so
  /// swapping it in makes "See forecast" repeat the whole wait.
  final List<ForecastProduct> refreshed = [];

  /// Products already finished when a given read STARTED. Non-empty means the
  /// page is loading serially — round 7 flagged this and round 8 found it still
  /// unguarded, costing ~0.5 s + 2.1 s + 1–9 s in sequence on a cold cache
  /// instead of the slowest of the three.
  final Map<ForecastProduct, Set<ForecastProduct>> completedBefore = {};
  final Set<ForecastProduct> _done = {};

  RiverDataEntry? _forKey(RiverDataKey key) {
    requested.add(key.product);
    completedBefore[key.product] = {..._done};
    final payload = byProduct[key.product];
    if (payload == null) return entry;
    return RiverDataEntry(
      key: key,
      window: _window(),
      unit: 'CFS',
      payload: payload,
    );
  }

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    final k = _forKey(key);
    if (failAll) {
      if (delay != null) await Future<void>.delayed(delay!);
      _done.add(key.product);
      throw Exception('simulated upstream failure');
    }
    // Marked done only AFTER the delay: marking it synchronously would make
    // every later read look like it waited, which is the fixture bug not the
    // production behaviour.
    if (delay != null) await Future<void>.delayed(delay!);
    _done.add(key.product);
    return k;
  }
  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) async {
    refreshed.add(key.product);
    return _forKey(key);
  }
  @override
  ValueListenable<RiverDataEntry?> watch(RiverDataKey key) =>
      ValueNotifier(entry);
  @override
  Future<void> ingest(RiverDataEntry e) async {}
}

/// A ReachDataProvider stand-in with no forecast — enough for the NWM page to
/// render the gauge/selector (peaks + detail show their loading states).
class _FakeReachDataProvider extends ChangeNotifier
    implements ReachDataProvider {
  @override
  ReachData? get currentReach => null;
  @override
  ForecastResponse? get currentForecast => null;
  @override
  Future<bool> loadReach(String reachId) async => true;
  @override
  Future<bool> loadAllData(String reachId) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FreshnessWindow _window() => FreshnessWindow(
      fetchedAt: DateTime.utc(2026, 7, 12, 12),
      validUntil: DateTime.utc(2026, 7, 12, 13),
    );

_FakeRepo _registerRepo(
  RiverDataEntry entry, {
  Map<ForecastProduct, Map<String, dynamic>> byProduct = const {},
  Duration? delay,
  bool failAll = false,
  _FakeGeocoder? geocoder,
}) {
  final sl = GetIt.instance;
  final repo =
      _FakeRepo(entry, byProduct: byProduct, delay: delay, failAll: failAll);
  sl.registerSingleton<IRiverDataRepository>(repo);
  sl.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
  sl.registerSingleton<IForecastService>(_StubForecastService());
  sl.registerSingleton<IGeocodingService>(geocoder ?? _FakeGeocoder());
  return repo;
}

Widget _wrap(Widget page) => CupertinoApp(
      home: ChangeNotifierProvider<ReachDataProvider>(
        create: (_) => _FakeReachDataProvider(),
        child: page,
      ),
    );

/// Pump past the async repository read without waiting on the looping shimmer.
Future<void> _pumpLoaded(WidgetTester tester) async {
  await tester.pump(); // let _load()'s await resolve
  await tester.pump(const Duration(milliseconds: 50)); // rebuild post-setState
}


/// The three narrow payloads, shaped as production produces them.
///
/// Thresholds are chosen so the ×35.31 CMS→CFS conversion CHANGES the category:
/// 30 CMS ≈ 1059 CFS, and the fixture flow is 640. Converted → below the 2-year
/// threshold (Normal); unconverted → above it. Review found the previous
/// fixture used 1200, which read Normal either way, so the category assertion
/// could not tell whether the conversion happened at all.
Map<ForecastProduct, Map<String, dynamic>> _narrowPayloads() => {
      ForecastProduct.reachMetadata: {
        'riverName': 'Test River',
        'latitude': 40.0,
        'longitude': -111.0,
      },
      ForecastProduct.analysisAssimilation: {
        'reach': {
          'reachId': '123',
          'name': 'Test River',
          'latitude': 40.0,
          'longitude': -111.0,
          'streamflow': ['short_range'],
        },
        'shortRange': <String, dynamic>{},
      },
      ForecastProduct.returnPeriods: {
        'returnPeriods': [
          {
            'feature_id': '123',
            'return_period_2': 30.0,
            'return_period_5': 60.0,
            'return_period_10': 90.0,
            'return_period_25': 150.0,
          },
        ],
      },
    };


GeoglowsForecast _geoglowsForecast() => GeoglowsForecast(
      riverId: '760021642',
      unit: 'ft³/s',
      generatedAt: DateTime.utc(2026, 8, 22),
      points: [
        for (var i = 0; i < 15; i++)
          GeoglowsForecastPoint(
            validTime: DateTime.now().toUtc().add(Duration(days: i)),
            median: 1000.0 - i * 5,
            lower: 900,
            upper: 1100,
          ),
      ],
      returnPeriods: const {2: 5000, 5: 8000, 10: 12000, 25: 20000},
    );

void main() {
  tearDown(() => GetIt.instance.reset());

  testWidgets('GEOGLOWS: gauge, category, header and 15-day forecast render',
      (tester) async {
    final forecast = GeoglowsForecast(
      riverId: '210230337',
      unit: 'ft³/s',
      generatedAt: DateTime.utc(2026, 7, 12),
      // Anchor the series at "now" so the step nearest the current time
      // (which currentMedian selects) is deterministically the first one
      // (median 1000) regardless of when the test runs.
      points: [
        for (var i = 0; i < 15; i++)
          GeoglowsForecastPoint(
            validTime: DateTime.now().toUtc().add(Duration(days: i)),
            median: 1000.0 - i * 5,
            lower: 900,
            upper: 1100,
          ),
      ],
      returnPeriods: const {2: 5000, 5: 8000, 10: 12000, 25: 20000},
    );
    _registerRepo(RiverDataEntry(
      key: const RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '210230337',
        product: ForecastProduct.geoglowsForecast,
      ),
      window: _window(),
      unit: 'CFS',
      payload: GeoglowsForecastPayload.encode(forecast),
    ));

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '210230337',
      source: ForecastSource.geoglows,
    )));
    await _pumpLoaded(tester);

    // Flow 1,000 sits below the 2-yr threshold -> Normal. The value lives in
    // the gauge's RichText ('1,000 ft³/s'), so match with findRichText.
    expect(find.text('1,000 ft³/s', findRichText: true), findsOneWidget);
    // GEOGLOWS values are converted at decode, so entry.unit already matches
    // the display unit here — the CMS→CFS discrimination this comment used to
    // describe belongs to the NWM test, not this one. GEOGLOWS decode
    // conversion is guarded by geoglows_forecast_payload_test.
    expect(find.text('NORMAL'), findsOneWidget);
    // No coordinate -> id fallback name.
    expect(find.text('Stream 210230337'), findsOneWidget);
    // Single GEOGLOWS range chip (15 days of points).
    expect(find.text('15-day forecast'), findsWidgets);
    expect(find.text('RETURN PERIOD'), findsOneWidget);
  });

  testWidgets('NWM: gauge, name/location and range selector render',
      (tester) async {
    const details = ReachDetailsData(
      riverName: 'Test River',
      formattedLocation: 'Testville, TS',
      currentFlow: 640,
      flowCategory: 'Normal',
      returnPeriods: {2: 1200, 5: 2400, 10: 3600, 25: 5800},
    );
    _registerRepo(
      RiverDataEntry(
        key: const RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '123',
          product: ForecastProduct.reachSummary,
        ),
        window: _window(),
        unit: 'CFS',
        payload: ReachSummaryPayload.encode(details),
      ),
      byProduct: _narrowPayloads(),
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);

    expect(find.text('640 ft³/s', findRichText: true), findsOneWidget);

    expect(find.text('NORMAL'), findsOneWidget);
    expect(find.text('Test River'), findsOneWidget);
    // Arrives from the injected geocoder after first paint. Assertable again
    // now that the geocoder is behind an interface — previously this was a
    // declared gap because the static could not be substituted.
    expect(find.text('Testville, TS'), findsOneWidget);
    // Range selector: Today + the two multi-day options (nominal while the
    // separate forecast series hasn't loaded in this fake).
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('10D'), findsOneWidget);
    expect(find.text('30D'), findsOneWidget);
  });
  // ADR 0011 Phase 1 — the page must read the same narrow products as the map
  // sheet, not the bundled reachSummary.
  //
  // REGRESSION: reverting this page to reachSummary reintroduces two defects at
  // once — the 156 KB medium-range fetch on the tap path, and the same current
  // flow living in two independently-cached entries so the gauge and the sheet
  // can disagree. Review proved the previous suite could not see either.
  testWidgets('NWM: reads the narrow products, never the bundle', (tester) async {
    final repo = _registerRepo(
      RiverDataEntry(
        key: const RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '123',
          product: ForecastProduct.reachSummary,
        ),
        window: _window(),
        unit: 'CFS',
        payload: const <String, dynamic>{},
      ),
      byProduct: {
        ForecastProduct.reachMetadata: {
          'riverName': 'Test River',
          'latitude': 40.0,
          'longitude': -111.0,
        },
        ForecastProduct.analysisAssimilation: {
          'reach': {
            'reachId': '123',
            'name': 'Test River',
            'latitude': 40.0,
            'longitude': -111.0,
            'streamflow': ['short_range'],
          },
          'shortRange': <String, dynamic>{},
        },
        ForecastProduct.returnPeriods: {
          'returnPeriods': [
            {'feature_id': '123', 'return_period_2': 1200.0},
          ],
        },
      },
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);

    expect(repo.requested, isNot(contains(ForecastProduct.reachSummary)),
        reason: 'the bundle pulls a 156 KB series this page never renders from '
            'it, and splits current flow across two cache entries');
    expect(repo.requested, containsAll([
      ForecastProduct.reachMetadata,
      ForecastProduct.analysisAssimilation,
      ForecastProduct.returnPeriods,
    ]));

    // REGRESSION: swapping read() for refresh() here left the suite green,
    // which would make this page bypass the cache the sheet just filled — the
    // exact "See forecast repeats the wait" regression.
    expect(repo.refreshed, isEmpty,
        reason: 'the page must read through the cache the sheet warmed');
  });

  // REGRESSION: replacing the page's Future.wait with three sequential awaits
  // left the whole suite green across two review rounds.
  testWidgets('NWM: the three reads are concurrent, not serial', (tester) async {
    final repo = _registerRepo(
      RiverDataEntry(
        key: const RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '123',
          product: ForecastProduct.reachSummary,
        ),
        window: _window(),
        unit: 'CFS',
        payload: const <String, dynamic>{},
      ),
      byProduct: _narrowPayloads(),
      delay: const Duration(milliseconds: 40),
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);
    await tester.pump(const Duration(milliseconds: 200));

    for (final p in repo.completedBefore.keys) {
      expect(repo.completedBefore[p], isEmpty,
          reason: '$p started only after another read finished — that is '
              'serial loading wearing a parallel costume');
    }
  });

  // REGRESSION: there was no forecast-page test in which a load fails, on
  // either branch. Deleting `_loading = false` from a catch left the page
  // rendering its skeleton forever, and _buildScroll checked _loading BEFORE
  // _error so a stuck flag masked the error entirely. Both branches now
  // covered, and the check order is reversed so it cannot be masked again.
  testWidgets('NWM: a failed load shows an error, not an endless skeleton',
      (tester) async {
    _registerRepo(
      RiverDataEntry(
        key: const RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '123',
          product: ForecastProduct.reachSummary,
        ),
        window: _window(),
        unit: 'CFS',
        payload: const <String, dynamic>{},
      ),
      failAll: true,
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);

    
    expect(find.textContaining('Failed to load'), findsOneWidget,
        reason: 'a failure must reach a terminal state, not shimmer forever');
  });

  testWidgets('GEOGLOWS: a failed load shows an error, not an endless skeleton',
      (tester) async {
    _registerRepo(
      RiverDataEntry(
        key: const RiverDataKey(
          source: ForecastSource.geoglows,
          reachId: '760021642',
          product: ForecastProduct.geoglowsForecast,
        ),
        window: _window(),
        unit: 'CMS',
        payload: const <String, dynamic>{},
      ),
      failAll: true,
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '760021642',
      source: ForecastSource.geoglows,
      lat: 12.1,
      lon: 15.3,
    )));
    await _pumpLoaded(tester);

    expect(find.textContaining('Failed to load forecast'), findsOneWidget,
        reason: 'a failure must reach a terminal state, not shimmer forever');
  });

  // REGRESSION: the GEOGLOWS branch awaited reverseGeocode inline before its
  // setState, so a Mapbox hop bounded only by AppConfig.httpTimeout gated the
  // whole page render — the defect already fixed on the sheet and the NWM path.
  testWidgets('GEOGLOWS: the page renders while the geocode is outstanding',
      (tester) async {
    final repo = _registerRepo(
      RiverDataEntry(
        key: const RiverDataKey(
          source: ForecastSource.geoglows,
          reachId: '760021642',
          product: ForecastProduct.geoglowsForecast,
        ),
        window: _window(),
        unit: 'CMS',
        payload: GeoglowsForecastPayload.encode(_geoglowsForecast()),
      ),
      geocoder: _FakeGeocoder(delay: const Duration(seconds: 20)),
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '760021642',
      source: ForecastSource.geoglows,
      lat: 12.1,
      lon: 15.3,
    )));
    await _pumpLoaded(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Stream'), findsWidgets,
        reason: 'a place label must never gate the page render');
    expect(find.textContaining('Failed to load'), findsNothing);
    // Same rule as every other surface: read through the cache the sheet
    // warmed. refresh() here re-fetches the ~20 s GEOGLOWS proxy on every
    // "See forecast".
    expect(repo.refreshed, isEmpty,
        reason: 'GEOGLOWS must not force a refresh either');

    await tester.pump(const Duration(seconds: 21));
    await tester.pump(const Duration(milliseconds: 50));
  });

  // Same class as the sheet's dispose test, swept here rather than waiting for
  // it to be reported on this surface. Popping the forecast page while its
  // three reads are outstanding is ordinary navigation; a setState after
  // dispose throws. This page has no dispose() — it relies on `mounted`, which
  // is correct, and this is what proves it.
  testWidgets('NWM: popping while reads are outstanding is safe', (tester) async {
    _registerRepo(
      RiverDataEntry(
        key: const RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '123',
          product: ForecastProduct.reachSummary,
        ),
        window: _window(),
        unit: 'CFS',
        payload: const <String, dynamic>{},
      ),
      byProduct: _narrowPayloads(),
      delay: const Duration(seconds: 5),
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
  });

  testWidgets('GEOGLOWS: popping while the geocode is outstanding is safe',
      (tester) async {
    _registerRepo(
      RiverDataEntry(
        key: const RiverDataKey(
          source: ForecastSource.geoglows,
          reachId: '760021642',
          product: ForecastProduct.geoglowsForecast,
        ),
        window: _window(),
        unit: 'CMS',
        payload: GeoglowsForecastPayload.encode(_geoglowsForecast()),
      ),
      geocoder: _FakeGeocoder(delay: const Duration(seconds: 5)),
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '760021642',
      source: ForecastSource.geoglows,
      lat: 12.1,
      lon: 15.3,
    )));
    await _pumpLoaded(tester);

    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
  });

}
