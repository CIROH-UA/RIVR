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
import 'package:shimmer/shimmer.dart';
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
  _FakeRepo(this.entry,
      {this.byProduct = const {},
      this.delay,
      this.delays = const {},
      this.failAll = false,
      this.failProducts = const {}});

  /// Per-product delays, so a slow product can be shown NOT to hold up a fast
  /// one. `/return-period` is measured at 1.0-9.1 s against a 10 ms cache hit.
  final Map<ForecastProduct, Duration> delays;
  final bool failAll;

  /// Products that throw while the rest succeed. `Future.wait` rejects on the
  /// first error, so before ADR 0011 guard 4 was swept here one of these
  /// blanked a page the other two could have filled.
  final Set<ForecastProduct> failProducts;
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
    final per = delays[key.product];
    if (per != null) {
      await Future<void>.delayed(per);
      _done.add(key.product);
      if (failProducts.contains(key.product) || failAll) {
        throw Exception('simulated failure for ${key.product}');
      }
      return k;
    }
    if (failProducts.contains(key.product)) {
      if (delay != null) await Future<void>.delayed(delay!);
      _done.add(key.product);
      throw Exception('simulated failure for ${key.product}');
    }
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
  /// Reach ids handed to loadReach. `loadReach` is the NWM series load; sending
  /// a GEOGLOWS id down it queries the wrong network entirely.
  final List<String> loaded = [];

  @override
  ReachData? get currentReach => null;
  @override
  ForecastResponse? get currentForecast => null;
  @override
  Future<bool> loadReach(String reachId) async {
    loaded.add(reachId);
    return true;
  }
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
  Map<ForecastProduct, Duration> delays = const {},
  bool failAll = false,
  Set<ForecastProduct> failProducts = const {},
  _FakeGeocoder? geocoder,
}) {
  final sl = GetIt.instance;
  final repo = _FakeRepo(entry,
      byProduct: byProduct,
      delay: delay,
      delays: delays,
      failAll: failAll,
      failProducts: failProducts);
  sl.registerSingleton<IRiverDataRepository>(repo);
  sl.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
  sl.registerSingleton<IForecastService>(_StubForecastService());
  sl.registerSingleton<IGeocodingService>(geocoder ?? _FakeGeocoder());
  return repo;
}

Widget _wrap(Widget page, {_FakeReachDataProvider? provider}) => CupertinoApp(
      home: ChangeNotifierProvider<ReachDataProvider>.value(
        value: provider ?? _FakeReachDataProvider(),
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
    // The return-period band comes from the PAGE's own FlowClassification
    // call, unlike NORMAL, which FlowGauge derives independently from the raw
    // props. Round 14 proved the distinction: hardcoding every classifier in
    // the page file left the suite green because only gauge-derived text was
    // asserted. 640 CFS under a 1,059 CFS 2-year threshold → below 2-yr band.
    expect(find.text('< 2 yr'), findsOneWidget);
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

    // Names what failed, as the map sheet does — guard 6. A generic apology
    // leaves the user unable to tell a dead river from a dead server.
    expect(find.textContaining('Failed to load'), findsOneWidget,
        reason: 'a failure must reach a terminal state, not shimmer forever');
    expect(find.textContaining('name'), findsOneWidget,
        reason: 'guard 6: the terminal state names the products that failed');
    expect(find.textContaining('flood risk'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget,
        reason: 'a terminal state with no way out is a dead end');
  });

  // REGRESSION (ADR 0011 guard 4, swept from the sheet): the page awaited its
  // three reads through a bare `Future.wait`, which rejects on the first error.
  // One product throwing therefore replaced a page the other two could have
  // filled with a full-screen failure. The sheet has settled per product since
  // Phase 1; this surface had not.
  testWidgets('NWM: one failed product does not blank the whole page',
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
      byProduct: _narrowPayloads(),
      failProducts: {ForecastProduct.returnPeriods},
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);

    expect(find.textContaining('Failed to load'), findsNothing,
        reason: 'name and current flow both landed — this page is usable');
    expect(find.text('Test River'), findsOneWidget);
    expect(find.text('640 ft³/s', findRichText: true), findsOneWidget);
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

    expect(find.textContaining("Failed to load this river's forecast"),
        findsOneWidget,
        reason: 'a failure must reach a terminal state, not shimmer forever');
    expect(find.text('Retry'), findsOneWidget,
        reason: 'a terminal state with no way out is a dead end');
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
    final geo = _FakeGeocoder();
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
      geocoder: geo,
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
    // REGRESSION (round 15, F43): the metadata callback fired the geocode for a
    // page that was already popped — round 14's "callbacks only mutate locals"
    // justification missed this side-effect.
    expect(geo.calls, 0,
        reason: 'a popped page must not start a Mapbox round-trip');
  });

  // The NWM branch's existing pop test pops DURING the reads, so `_load()`
  // returns on `!mounted` and `_fillPlaceLabel` never starts — the geocode
  // callback's own mounted check was therefore never exercised. Review round 11
  // found the same hole on the weekly outlook. This lets the load finish, then
  // pops while the geocode is still in flight.
  testWidgets('NWM: popping while the place-label geocode is outstanding is safe',
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
      byProduct: _narrowPayloads(),
      geocoder: _FakeGeocoder(delay: const Duration(seconds: 5)),
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);
    // The page has rendered and the geocode is outstanding.
    expect(find.text('Test River'), findsOneWidget);

    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
  });

  // The GEOGLOWS branch had no test that pops while its READ is outstanding —
  // only one that pops after the load completed, so the mounted check guarding
  // the post-load setState was unfalsifiable. Its NWM sibling has had this
  // since round 9.
  testWidgets('GEOGLOWS: popping while the read is outstanding is safe',
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
      delay: const Duration(seconds: 5),
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '760021642',
      source: ForecastSource.geoglows,
      lat: 12.1,
      lon: 15.3,
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

  // What this DOES guard: a second failure is still terminal — Retry sets
  // _loading true and clears _error, and if the reload's own failure did not
  // restore the error the page would sit on a skeleton forever.
  //
  // What it does NOT guard, corrected after review round 11 measured it: the
  // _error/_loading precedence. `_retry()` clears _error before setting
  // _loading, so the both-set state is never constructed here; reversing
  // `loadViewStateFor` leaves this whole file green and only
  // load_view_state_test.dart dies. The previous comment claimed otherwise.
  testWidgets('NWM: a failed retry is terminal too, not an endless skeleton',
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

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(find.textContaining('Failed to load'), findsOneWidget,
        reason: 'a retry that fails again must land back on a terminal state, '
            'not leave the page shimmering');
  });

  // REGRESSION: hardcoding `_categoryFor(...) => 0` — the page's entire flood
  // classification, feeding the gauge tint, the zone colours, the stat card and
  // the threshold bands — left the suite green, because the only category
  // assertion was NORMAL, which is exactly what a broken classifier returns.
  testWidgets('NWM: an elevated flow classifies as elevated, not Normal',
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
      // 2-yr threshold 5 CMS ≈ 177 CFS; the stubbed flow is 640 CFS, so this
      // sits above it and must NOT read Normal.
      byProduct: {
        ..._narrowPayloads(),
        ForecastProduct.returnPeriods: {
          'returnPeriods': [
            {
              'feature_id': '123',
              'return_period_2': 5.0,
              'return_period_5': 8.0,
              'return_period_10': 12.0,
              'return_period_25': 20.0,
            },
          ],
        },
      },
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);

    expect(find.text('NORMAL'), findsNothing,
        reason: 'a flow above every threshold must not classify as Normal — '
            'a hardcoded classifier returns Normal and would pass otherwise');
    // The page's own classifier, not the gauge's: 640 CFS against converted
    // thresholds ≈ {177, 282, 424, 706} sits in the 10-25 yr band. A page-level
    // classifier stuck on 0 renders '< 2 yr' here and the gauge assertion
    // above cannot see it — it classifies independently from the raw props.
    expect(find.text('10–25 yr'), findsOneWidget,
        reason: 'the stat band, gradient tint and chart zones all derive from '
            'the page classifier; this is the rendered text among them');
    expect(find.text('< 2 yr'), findsNothing);
  });

  // REGRESSION (M20): the postFrameCallback that kicks off the NWM series load
  // sits behind `if (!_isGeoglows)`, and nothing pinned the gate. Dropping it
  // sends a GEOGLOWS river id to ReachDataProvider.loadReach — the NWM loader —
  // which fetches a different network's reach by the same number, warms the
  // session cache with it, and can only end as a wrong river or a wasted call.
  // The two tests are a pair on purpose: one alone passes under the mutation
  // that deletes the call outright.
  testWidgets('GEOGLOWS: the NWM series load is never kicked off',
      (tester) async {
    final provider = _FakeReachDataProvider();
    _registerRepo(RiverDataEntry(
      key: const RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '760021642',
        product: ForecastProduct.geoglowsForecast,
      ),
      window: _window(),
      unit: 'CMS',
      payload: GeoglowsForecastPayload.encode(_geoglowsForecast()),
    ));

    await tester.pumpWidget(_wrap(
      const ReachForecastPage(
        reachId: '760021642',
        source: ForecastSource.geoglows,
        lat: 12.1,
        lon: 15.3,
      ),
      provider: provider,
    ));
    await _pumpLoaded(tester);
    await tester.pump(const Duration(milliseconds: 100));

    expect(provider.loaded, isEmpty,
        reason: 'loadReach is the NWM loader — a GEOGLOWS id sent to it '
            'resolves to a different river, or to nothing');
  });

  // REGRESSION (ADR 0011 guard 2, proved broken here in round 13): the three
  // reads were batched through one `Future.wait` and one `setState`, so the
  // page showed nothing until the SLOWEST landed. With `/return-period` at
  // 1.0-9.1 s, a name and a flow that arrived in 10 ms sat invisible for five
  // seconds. The sheet has settled per product since Phase 1; this page did
  // not, and its concurrency test could not see the difference — concurrent
  // reads and a batched render look identical to it.
  testWidgets('NWM: a fast product renders while a slow one is still out',
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
      byProduct: _narrowPayloads(),
      delays: const {
        ForecastProduct.reachMetadata: Duration(milliseconds: 10),
        ForecastProduct.analysisAssimilation: Duration(milliseconds: 10),
        ForecastProduct.returnPeriods: Duration(seconds: 5),
      },
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Test River'), findsOneWidget,
        reason: 'the name landed 4.99 s ago; batching hides it behind the '
            'slowest read');
    expect(find.text('640 ft³/s', findRichText: true), findsOneWidget,
        reason: 'so did the flow — this is guard 2');

    // The metadata branch publishes for ITSELF. With metadata and flow on the
    // same delay, deleting the metadata branch's publish() was invisible — the
    // flow branch's publish() picked up the already-assigned name (round 14,
    // F38). Production's measured ordering is metadata 0.5 s, flow 2.1 s, so
    // that deletion would blank the title for the gap.

    // The geocoded label is on screen before the slow product lands…
    expect(find.text('Testville, TS'), findsOneWidget);

    // Let the slow product land so the test leaves no pending timer.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('NORMAL'), findsOneWidget,
        reason: 'and the category completes when the thresholds arrive');
    // REGRESSION (round 14, F29 — a live bug this timing produced): publish()
    // rebuilt _details wholesale from the product values, so the return-periods
    // landing wiped a geocoded label that was already on screen. Present at
    // 300 ms, gone at 6 s. The label now lives in its own field.
    expect(find.text('Testville, TS'), findsOneWidget,
        reason: 'a later product landing must not wipe the geocoded label');
  });

  // Guard 1's shape one surface over (round 17, F54): the loading view could
  // be replaced with SizedBox.shrink() — a blank page for up to the slowest
  // read — with the suite green. Shimmer is the skeleton's top-level widget.
  testWidgets('a loading page shows a skeleton, not a blank', (tester) async {
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
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(Shimmer), findsWidgets,
        reason: 'nothing has landed; a blank page and a skeleton are the same '
            'to every existing assertion, and only one of them is acceptable');

    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('NWM: the name renders while flow AND thresholds are still out',
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
      byProduct: _narrowPayloads(),
      delays: const {
        ForecastProduct.reachMetadata: Duration(milliseconds: 10),
        ForecastProduct.analysisAssimilation: Duration(seconds: 5),
        ForecastProduct.returnPeriods: Duration(seconds: 5),
      },
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Test River'), findsOneWidget,
        reason: 'only the metadata branch has landed, so only its own '
            'publish() can have put the name on screen');

    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 50));
  });

  // REGRESSION (round 13): every dispose test popped while a load was
  // SUCCEEDING, so the `mounted` check on the failure path was unfalsifiable on
  // all four surfaces. Popping during a failing load is just as ordinary.
  testWidgets('NWM: popping while a FAILING load is outstanding is safe',
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
      delays: const {
        ForecastProduct.reachMetadata: Duration(seconds: 5),
        ForecastProduct.analysisAssimilation: Duration(seconds: 5),
        ForecastProduct.returnPeriods: Duration(seconds: 5),
      },
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

  testWidgets('GEOGLOWS: popping while a FAILING load is outstanding is safe',
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
      delay: const Duration(seconds: 5),
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '760021642',
      source: ForecastSource.geoglows,
      lat: 12.1,
      lon: 15.3,
    )));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
  });

  // REGRESSION (round 14, F32): `settled < 3` could be weakened to `< 1` with
  // the suite green — an error card painted over reads still in flight. The
  // sheet has had this guard since its own review round; it was not swept here.
  testWidgets('NWM: no error card while a read is still outstanding',
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
      byProduct: _narrowPayloads(),
      failProducts: {ForecastProduct.returnPeriods},
      delays: const {
        ForecastProduct.returnPeriods: Duration(milliseconds: 10),
        ForecastProduct.reachMetadata: Duration(seconds: 5),
        ForecastProduct.analysisAssimilation: Duration(seconds: 5),
      },
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    // The failing product has settled; the two that will succeed have not.
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Failed to load'), findsNothing,
        reason: 'one settled failure out of three is not a verdict — the page '
            'must wait for all three before declaring anything');

    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Test River'), findsOneWidget,
        reason: 'and when the others land the page is a page, not an error');
  });

  // REGRESSION (round 14, F33): deleting `anySucceeded = true` from the
  // metadata branch survived the suite — under it, the 2026-08-22 outage shape
  // (/reaches answers, every /streamflow series 504s) renders a full-screen
  // failure over a river whose name loaded fine. The sheet has this exact
  // guard; the page's partial-failure test only failed returnPeriods.
  testWidgets('NWM: identity alone is a page, not an error', (tester) async {
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
      failProducts: {
        ForecastProduct.analysisAssimilation,
        ForecastProduct.returnPeriods,
      },
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);

    expect(find.textContaining('Failed to load'), findsNothing,
        reason: 'the name loaded; a named river with no flow is usable');
    expect(find.text('Test River'), findsOneWidget);
    // And the missing flow is SAID, not implied by dashes (round 14, F36) —
    // the sheet states it and this surface silently showed "—" everywhere.
    expect(find.textContaining('not available'), findsOneWidget,
        reason: 'the user must be told the flow is missing, not left to '
            'interpret em dashes');
    // …with a way out (round 16, F51): a missing flow is often a transient
    // upstream failure, and this state was a dead end on two of four surfaces.
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('NWM: Retry from the no-flow state actually refetches',
      (tester) async {
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
      failProducts: {
        ForecastProduct.analysisAssimilation,
        ForecastProduct.returnPeriods,
      },
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);
    final before = repo.requested.length;

    await tester.tap(find.text('Retry'));
    await _pumpLoaded(tester);

    expect(repo.requested.length, greaterThan(before),
        reason: 'a Retry that issues no reads is decoration');
  });

  // REGRESSION (round 14, F34): a flow payload that decodes to null was not
  // named in the all-failed error card — `failed.add('current flow')` was
  // deletable with the suite green. The sheet grew this guard for the same
  // reason; not swept here.
  testWidgets('NWM: a decoded-null flow is named in the error card',
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
      byProduct: {
        ..._narrowPayloads(),
        // An entry whose body the codec cannot read: CurrentFlowPayload.decode
        // catches internally and yields null — a 200 with nothing usable,
        // distinct from a thrown read failure.
        ForecastProduct.analysisAssimilation: <String, dynamic>{},
      },
      failProducts: {
        ForecastProduct.reachMetadata,
        ForecastProduct.returnPeriods,
      },
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);

    expect(find.textContaining('current flow'), findsOneWidget,
        reason: 'an upstream that answered with nothing usable failed this '
            'product; unnamed, the error card lies about what broke');
  });

  // REGRESSION (round 12, class g): every GetIt lookup used to sit inside
  // `_load()`'s try, so an unresolvable dependency was caught and rendered as
  // "Failed to load…" with a Retry that could never succeed. Round 11 fixed
  // this on the Weekly Outlook only; both branches here had it live while three
  // separate comments claimed otherwise.
  group('a missing registration is a wiring bug, not a load failure', () {
    testWidgets('NWM branch', (tester) async {
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
      );
      GetIt.instance.unregister<IRiverDataRepository>();

      await tester.pumpWidget(_wrap(const ReachForecastPage(
        reachId: '123',
        source: ForecastSource.nwm,
      )));
      // Taken straight after the mount: the lookup runs in initState, and a
      // later pump would have already consumed the pending exception.
      final thrown = tester.takeException();
      await _pumpLoaded(tester);

      expect(thrown, isNotNull,
          reason: 'an unresolvable dependency must surface where it happened');
      expect(find.textContaining('Failed to load'), findsNothing,
          reason: 'telling the user to Retry a DI bug is a lie — the retry '
              'resolves the same missing type and fails identically');
    });

    // Round 15 (F44): the geocoder was the one dependency still resolved
    // inside a caught future, where a missing registration degraded to a debug
    // log line. Guard 8's rule is initState, and now it is there.
    testWidgets('the geocoder counts too', (tester) async {
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
      );
      GetIt.instance.unregister<IGeocodingService>();

      await tester.pumpWidget(_wrap(const ReachForecastPage(
        reachId: '123',
        source: ForecastSource.nwm,
      )));
      final thrown = tester.takeException();
      await _pumpLoaded(tester);

      expect(thrown, isNotNull,
          reason: 'resolved lazily inside a caught future, this wiring bug '
              'was a silent debug log and a permanently missing label');
    });

    testWidgets('GEOGLOWS branch', (tester) async {
      _registerRepo(RiverDataEntry(
        key: const RiverDataKey(
          source: ForecastSource.geoglows,
          reachId: '760021642',
          product: ForecastProduct.geoglowsForecast,
        ),
        window: _window(),
        unit: 'CMS',
        payload: GeoglowsForecastPayload.encode(_geoglowsForecast()),
      ));
      GetIt.instance.unregister<IRiverDataRepository>();

      await tester.pumpWidget(_wrap(const ReachForecastPage(
        reachId: '760021642',
        source: ForecastSource.geoglows,
        lat: 12.1,
        lon: 15.3,
      )));
      final thrown = tester.takeException();
      await _pumpLoaded(tester);

      expect(thrown, isNotNull);
      expect(find.textContaining('Failed to load'), findsNothing);
    });
  });

  // REGRESSION (round 12, class a on the GEOGLOWS branch): deleting
  // `_fillGeoglowsPlaceLabel` outright left the whole suite green. That call is
  // the entire identity of a GEOGLOWS reach — the existing test asserts
  // `textContaining('Stream')`, which the `Stream <id>` fallback satisfies, so
  // it cannot see the label's absence. The NWM branch and the weekly outlook
  // both had this guard; this branch did not.
  testWidgets('GEOGLOWS: the place label arrives after the page has rendered',
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
      geocoder: _FakeGeocoder(delay: const Duration(milliseconds: 400)),
    );

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '760021642',
      source: ForecastSource.geoglows,
      lat: 12.1,
      lon: 15.3,
    )));
    await _pumpLoaded(tester);

    expect(find.text('Stream 760021642'), findsWidgets,
        reason: 'the id fallback holds the header while the geocode is out');

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Stream near Testville'), findsOneWidget,
        reason: 'the label supplies a GEOGLOWS reach its whole identity; '
            'deleting the fill loses it silently');
  });

  testWidgets('NWM: the series load IS kicked off', (tester) async {
    final provider = _FakeReachDataProvider();
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
    );

    await tester.pumpWidget(_wrap(
      const ReachForecastPage(reachId: '123', source: ForecastSource.nwm),
      provider: provider,
    ));
    await _pumpLoaded(tester);
    await tester.pump(const Duration(milliseconds: 100));

    expect(provider.loaded, contains('123'),
        reason: 'without it the stat-card peaks and the embedded hourly/daily '
            'widgets never get a forecast at all');
  });
}
