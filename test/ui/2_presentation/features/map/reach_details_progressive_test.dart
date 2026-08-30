// test/ui/2_presentation/features/map/reach_details_progressive_test.dart
//
// ADR 0011 Phase 1 guards — the map detail sheet renders progressively.
//
// What this exists to prevent: the sheet used to make ONE `reachSummary` read,
// which looked cheap at the call site and was not. Building that payload fetched
// reach info, current flow, return periods AND a medium-range forecast
// serially, of which the 156 KB medium-range call was the bulk. (The
// end-to-end total has not been measured on device — the per-call medians have.) The sheet never rendered a forecast series at all; its peak comes
// from the map tile.
//
// Guard 3 ("medium range is never requested") is the one that would catch a
// regression to that design, and it FAILS against the previous implementation —
// which requested `reachSummary`, whose fetch pulls medium range internally.

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/components/reach_action_buttons.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_details_bottom_sheet.dart';

// ── Fakes ────────────────────────────────────────────────────────────────────

/// Injectable geocoder: lets the tests pin both directions — that the label
/// arrives, and (in data_sources_test) that the data source never asks for it.
/// Also stops widget tests making live Mapbox calls, which review found them
/// doing twice per run.
class _FakeGeocoder implements IGeocodingService {
  _FakeGeocoder({this.label = 'Provo, UT', this.delay});
  final String? label;
  final Duration? delay;
  int calls = 0;

  @override
  Future<Map<String, String?>> reverseGeocode(double lat, double lon) async {
    calls++;
    return {'city': 'Provo', 'state': 'UT', 'country': 'US'};
  }

  @override
  Future<String?> placeLabel(double? lat, double? lon) async {
    calls++;
    if (delay != null) await Future<void>.delayed(delay!);
    return label;
  }
}

class _StubUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
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

/// Returns a fixed current flow regardless of payload — the extraction itself
/// is ForecastService's job and is covered by its own tests.
class _StubForecastService implements IForecastService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FreshnessWindow _window() => FreshnessWindow(
      fetchedAt: DateTime.utc(2026, 8, 22, 12),
      validUntil: DateTime.utc(2026, 8, 22, 13),
    );

/// Records every product requested, and lets each one be delayed independently
/// so "renders as it lands" is observable rather than asserted by faith.
class _RecordingRepo implements IRiverDataRepository {

  // Phase 7: the fakes never go out of sync — a test that needs the indicator
  // drives it explicitly rather than inheriting a default that could hide a
  // real regression.
  @override
  final ValueListenable<bool> outOfSync = ValueNotifier<bool>(false);
  _RecordingRepo({
    this.delays = const {},
    this.failures = const {},
    this.undecodableFlow = false,
    this.lowThresholds = false,
  });

  /// A 200 whose body the threshold codec cannot read — decodes to null,
  /// which is neither a success nor a named failure. Set by the retry test
  /// between attempts, on the same instance.
  bool undecodableThresholds = false;

  /// Return periods low enough that the stubbed 1,234 flow clears them, so the
  /// sheet's classification can be asserted in BOTH directions. Without it the
  /// only fixture read Normal — which is exactly what a classifier hardcoded to
  /// 'Normal' returns, so the category tests could not tell the two apart.
  final bool lowThresholds;

  /// Returns a 200 whose body the flow codec cannot read — distinct from a
  /// thrown failure, and a path guard 6 never exercised.
  final bool undecodableFlow;

  /// product -> how long its read takes.
  final Map<ForecastProduct, Duration> delays;

  /// products whose read should throw. Mutable: the retry test reshapes the
  /// failure set between attempts on the SAME instance, because the sheet
  /// resolves its repository once in initState.
  Set<ForecastProduct> failures;

  final List<ForecastProduct> requested = [];

  /// Wall-clock start of each read. Position in [requested] is not enough:
  /// review proved a guard asserting only on order still passed when the
  /// prefetch was moved to start concurrently with first paint.
  final Map<ForecastProduct, DateTime> startedAt = {};

  /// Products whose read had already completed when a given product started.
  final Map<ForecastProduct, Set<ForecastProduct>> completedBefore = {};
  final Set<ForecastProduct> _done = {};

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    requested.add(key.product);
    startedAt[key.product] = DateTime.now();
    completedBefore[key.product] = {..._done};
    final d = delays[key.product];
    if (d != null) await Future<void>.delayed(d);
    if (failures.contains(key.product)) {
      _done.add(key.product);
      throw Exception('simulated failure for ${key.product}');
    }
    _done.add(key.product);
    return RiverDataEntry(
      key: key,
      window: _window(),
      unit: 'CFS',
      payload: _payloadFor(key.product),
    );
  }

  Map<String, dynamic> _payloadFor(ForecastProduct p) {
    switch (p) {
      case ForecastProduct.reachMetadata:
        return {
          'riverName': 'White River',
          // NO formattedLocation. Production's reachMetadata deliberately does
          // not geocode, so this is empty on a cold cache and the consumer
          // fills it. A fixture supplying it would make the tests pass over a
          // path that is broken in the app — review found exactly that on the
          // forecast page.
          'latitude': 40.2,
          'longitude': -111.6,
        };
      case ForecastProduct.geoglowsForecast:
        // A real payload, so the GEOGLOWS branch has a SUCCESS path under test.
        // Review found all three of its tests used the empty default and so
        // exercised only the error path. `lowThresholds` mirrors the NWM
        // fixture: the same ~800 median against thresholds 100× apart, so the
        // category comparison works on this branch too.
        return GeoglowsForecastPayload.encode(GeoglowsForecast(
          riverId: '760021642',
          unit: 'ft³/s',
          generatedAt: DateTime.utc(2026, 8, 22),
          points: [
            for (var i = 0; i < 15; i++)
              GeoglowsForecastPoint(
                validTime: DateTime.now().toUtc().add(Duration(days: i)),
                median: 800.0 - i * 5,
                lower: 700,
                upper: 900,
              ),
          ],
          returnPeriods: lowThresholds
              ? const {2: 50, 5: 80, 10: 120, 25: 200}
              : const {2: 5000, 5: 8000},
        ));
      case ForecastProduct.returnPeriods:
        if (undecodableThresholds) return <String, dynamic>{};
        // Shape mirrors the real API: one object per reach with
        // `return_period_<years>` keys (see ReachDataDto.fromReturnPeriodApi).
        return {
          'returnPeriods': [
            {
              'feature_id': '9962444',
              // Native CMS. 100 CMS ≈ 3,531 CFS, above the 1,234 CFS stub, so
              // the default fixture is Normal; the low set is ≈35 CFS and is
              // cleared several times over.
              'return_period_2': lowThresholds ? 1.0 : 100.0,
              'return_period_5': lowThresholds ? 2.0 : 200.0,
              'return_period_10': lowThresholds ? 3.0 : 300.0,
              'return_period_25': lowThresholds ? 4.0 : 400.0,
            },
          ],
        };
      case ForecastProduct.currentFlow:
        if (undecodableFlow) return <String, dynamic>{};
        // Must be decodable: `fromApiResponse` reads json['reach'], and an
        // empty map made it throw. Review found that every "passing" test was
        // silently rendering "not available" instead of a flow value.
        return {
          // Mirrors the fields ReachDataDto.fromNoaaApi actually requires —
          // reachId, name, latitude, longitude and a streamflow list. A
          // fixture missing any of them throws, which review found was
          // silently rendering "not available" in every green test.
          'reach': {
            'reachId': '9962444',
            'name': 'White River',
            'latitude': 40.2,
            'longitude': -111.6,
            'streamflow': ['short_range'],
          },
          'shortRange': {
            'series': {
              'referenceTime': '2026-08-23T12:00:00',
              'units': 'ft³/s',
              'data': [
                {
                  'validTime': DateTime.now()
                      .toUtc()
                      .add(const Duration(hours: 1))
                      .toIso8601String(),
                  'flow': 1234.0,
                },
              ],
            },
          },
        };
      default:
        return <String, dynamic>{};
    }
  }

  /// Tracked separately: review swapped `read` for `refresh` at both surfaces
  /// and every test passed. `refresh` skips the cache entirely, so that turns
  /// each tap into three network fetches and makes "See forecast" repeat the
  /// whole wait — the regression round 2 was opened to fix.
  final List<ForecastProduct> refreshed = [];

  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) {
    refreshed.add(key.product);
    return read(key);
  }
  @override
  ValueListenable<RiverDataEntry?> watch(RiverDataKey key) =>
      ValueNotifier(null);
  @override
  Future<void> ingest(RiverDataEntry e) async {}
}

/// GEOGLOWS reaches are everything outside the US, and Phase 1's "you are done
/// when" says *any* stream. Review found this branch had zero tests, and the
/// exact terminal-state defect fixed on the NWM branch was live here.
SelectedReach _geoglowsReach() => SelectedReach(
      reachId: '760021642',
      source: ForecastSource.geoglows,
      streamOrder: 3,
      latitude: 12.1,
      longitude: 15.3,
      selectedAt: DateTime.utc(2026, 8, 22, 12),
    );

SelectedReach _reach() => SelectedReach(
      reachId: '9962444',
      source: ForecastSource.nwm,
      streamOrder: 4,
      latitude: 40.2,
      longitude: -111.6,
      selectedAt: DateTime.utc(2026, 8, 22, 12),
    );

void _register(_RecordingRepo repo, {_FakeGeocoder? geocoder}) {
  final sl = GetIt.instance;
  sl.registerSingleton<IRiverDataRepository>(repo);
  sl.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
  sl.registerSingleton<IForecastService>(_StubForecastService());
  sl.registerSingleton<IGeocodingService>(geocoder ?? _FakeGeocoder());
}

/// A child of the sheet consumes FavoritesProvider (the favourite toggle), so
/// one must be above it. Bounded height because the sheet sizes to its content.
class _FakeFavorites extends ChangeNotifier implements FavoritesProvider {
  @override
  bool isFavorite(String reachId) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(Widget w) => CupertinoApp(
      home: ChangeNotifierProvider<FavoritesProvider>(
        create: (_) => _FakeFavorites(),
        child: CupertinoPageScaffold(
          child: SizedBox(height: 800, child: SingleChildScrollView(child: w)),
        ),
      ),
    );

/// The sheet shows a CupertinoActivityIndicator while loading, which animates
/// forever — `pumpAndSettle` would time out rather than settle. Pump explicitly
/// past the async reads instead (same approach as reach_forecast_page_test).
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  tearDown(() => GetIt.instance.reset());

  group('guard 1 — the sheet is up before any read completes', () {
    // The <500ms half needs a device capture. This half does not: with every
    // read hung, the sheet must still be on screen with its skeleton.
    testWidgets('renders with zero completed reads', (t) async {
      final repo = _RecordingRepo(delays: {
        ForecastProduct.reachMetadata: const Duration(seconds: 30),
        ForecastProduct.currentFlow: const Duration(seconds: 30),
        ForecastProduct.returnPeriods: const Duration(seconds: 30),
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await t.pump();

      expect(find.byType(ReachDetailsBottomSheet), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsWidgets,
          reason: 'a skeleton, not a blank sheet');
      // The title-block skeleton specifically (round 17, F53): the assertion
      // above is satisfied by the header's trailing spinner alone, so the
      // whole title skeleton was deletable with the suite green.
      expect(find.byType(DecoratedBox), findsWidgets);
      expect(
          find.byWidgetPredicate((w) =>
              w is Container &&
              w.constraints?.maxHeight != null &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).borderRadius != null),
          findsWidgets,
          reason: 'the grey title placeholder bars must render while loading');
      expect(repo.requested, hasLength(3),
          reason: 'all three issued, none completed');

      await t.pump(const Duration(seconds: 31));
      await _settle(t);
    });
  });

  group('guard 3 — the 156 KB medium-range fetch is never requested', () {
    // REGRESSION: the old sheet read `reachSummary`, whose fetch pulls medium
    // range internally. This assertion fails against that implementation.
    testWidgets('sheet requests only the three narrow products', (t) async {
      final repo = _RecordingRepo();
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      // The distinction that matters is *blocking* vs *background*. The sheet's
      // own reads — the ones first paint waits on — must be the three narrow
      // products. No warm exists: the forecast page reads these same three
      // keys, so it is warm without anyone warming it.
      final blocking = repo.requested.take(3).toSet();
      expect(blocking, {
        ForecastProduct.reachMetadata,
        ForecastProduct.currentFlow,
        ForecastProduct.returnPeriods,
      }, reason: 'first paint must not wait on the 156 KB bundle');
      expect(blocking, isNot(contains(ForecastProduct.mediumRange)));
      expect(blocking, isNot(contains(ForecastProduct.reachSummary)),
          reason: 'reachSummary drags medium range in behind it');
    });
  });

  group('guard 5 — the sheet issues exactly its three reads', () {
    // The sheet used to warm `reachSummary` for the forecast page. That is gone:
    // the forecast page now reads these same three keys, so it is warm without
    // anyone warming it — and the flow number is literally the same cache entry
    // on both screens rather than two entries fetched moments apart.
    testWidgets('no fourth read rides along with a stream tap', (t) async {
      final repo = _RecordingRepo();
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(repo.requested.toSet(), {
        ForecastProduct.reachMetadata,
        ForecastProduct.currentFlow,
        ForecastProduct.returnPeriods,
      });
      expect(repo.requested, isNot(contains(ForecastProduct.reachSummary)),
          reason: 'reachSummary pulls the 156 KB series two layers down');
      expect(repo.requested, isNot(contains(ForecastProduct.longRange)));
    });

    // Uses startedAt rather than list position. Review flagged that the previous
    // assertion checked only order in a list recorded at call time — the exact
    // mechanism the guard text says is insufficient — and that the start-time
    // scaffolding built for a stronger check was never read by any test.
    testWidgets('all three start together; none waits on another', (t) async {
      // All three delayed, so none can complete inside its own synchronous
      // body and be counted as "already done" by the next one.
      final repo = _RecordingRepo(delays: {
        ForecastProduct.reachMetadata: const Duration(milliseconds: 80),
        ForecastProduct.currentFlow: const Duration(milliseconds: 40),
        ForecastProduct.returnPeriods: const Duration(milliseconds: 60),
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(repo.startedAt, hasLength(3));
      for (final p in repo.startedAt.keys) {
        expect(repo.completedBefore[p], isEmpty,
            reason: '$p started only after another read finished — that is '
                'serial loading wearing a parallel costume');
      }
    });
  });

  group('guard 2 — values render as they land, not all at once', () {
    testWidgets('the name appears while flow is still outstanding', (t) async {
      final repo = _RecordingRepo(delays: {
        ForecastProduct.reachMetadata: const Duration(milliseconds: 50),
        ForecastProduct.currentFlow: const Duration(seconds: 30),
        ForecastProduct.returnPeriods: const Duration(seconds: 30),
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await t.pump(const Duration(milliseconds: 200));

      expect(find.text('White River'), findsOneWidget,
          reason: 'the river is named while flow is still 30s away');

      await t.pump(const Duration(seconds: 31));
      await _settle(t);
    });

    // REGRESSION: the first implementation joined flow and thresholds with
    // Future.wait, so a slow threshold read hid a flow value that was ready.
    // This is the guard that catches that.
    testWidgets('the flow value renders even while thresholds are 30s away',
        (t) async {
      final repo = _RecordingRepo(delays: {
        ForecastProduct.reachMetadata: const Duration(milliseconds: 10),
        ForecastProduct.currentFlow: const Duration(milliseconds: 20),
        ForecastProduct.returnPeriods: const Duration(seconds: 30),
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await t.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('1.2K'), findsWidgets,
          reason: 'flow must not wait on a separate threshold call');
      expect(find.textContaining('not available'), findsNothing);

      await t.pump(const Duration(seconds: 31));
      await _settle(t);
    });

    // Review found every previously-"passing" test rendered "not available"
    // because the fixture could not decode. Pin that a number really shows.
    testWidgets('a real flow value reaches the screen', (t) async {
      final repo = _RecordingRepo();
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(find.textContaining('1.2K'), findsWidgets);
    });
  });

  group('guard 4 — one slow read never blocks the others', () {
    testWidgets('thresholds failing outright still leaves name and flow',
        (t) async {
      final repo = _RecordingRepo(failures: {ForecastProduct.returnPeriods});
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(find.text('White River'), findsOneWidget);
      expect(find.textContaining('1.2K'), findsWidgets);
      expect(find.textContaining('Failed to load'), findsNothing,
          reason: 'losing the flood category is not losing the sheet');
    });
  });

  group('guard 6 — partial failure still yields a usable sheet', () {
    // The 2026-08-22 outage: /streamflow 504 for every series while /reaches
    // kept answering. A named river with no flow beats an error card.
    testWidgets('flow fails but identity succeeds — no error card', (t) async {
      final repo = _RecordingRepo(failures: {
        ForecastProduct.currentFlow,
        ForecastProduct.returnPeriods,
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(find.text('White River'), findsOneWidget);
      expect(find.textContaining('Failed to load'), findsNothing,
          reason: 'identity succeeded — that is a usable sheet, not a failure');
    });

    testWidgets('everything fails — the sheet says so and stops spinning',
        (t) async {
      final repo = _RecordingRepo(failures: {
        ForecastProduct.reachMetadata,
        ForecastProduct.currentFlow,
        ForecastProduct.returnPeriods,
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(find.textContaining('Failed to load'), findsOneWidget,
          reason: 'total failure must reach a terminal state, never a spinner');

      // REGRESSION: the card used to say the same thing whatever broke, and
      // offered no way out.
      expect(find.textContaining('current flow'), findsOneWidget,
          reason: 'the card must name what failed');
      expect(find.text('Retry'), findsOneWidget,
          reason: 'a terminal state with no way out is a dead end');

      // The test is named "stops spinning" — assert it. Removing the loading
      // resets in markSettled left this green, and with _isLoadingFlow stuck
      // true the header's close button is replaced by a spinner, so the sheet
      // cannot be dismissed from the header at all.
      expect(find.byType(CupertinoActivityIndicator), findsNothing,
          reason: 'an error card over a live spinner is not a terminal state');
    });

    testWidgets('Retry re-issues the reads', (t) async {
      final repo = _RecordingRepo(failures: {
        ForecastProduct.reachMetadata,
        ForecastProduct.currentFlow,
        ForecastProduct.returnPeriods,
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);
      final before = repo.requested.length;

      await t.tap(find.text('Retry'));
      await _settle(t);

      expect(repo.requested.length, greaterThan(before));
    });
  });
  group('the place label is filled off the critical path', () {
    // REGRESSION: deleting both _fillPlaceLabel call sites left the whole suite
    // green, even though it is now the ONLY thing preserving the "Provo, UT"
    // label the removed reachSummary path used to supply.
    testWidgets('the label arrives after the sheet is already usable', (t) async {
      final geo = _FakeGeocoder(label: 'Provo, UT');
      _register(_RecordingRepo(), geocoder: geo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(geo.calls, greaterThan(0),
          reason: 'reachMetadata deliberately does not geocode, so the '
              'consumer must');
      // AND that the answer is kept. Round 13 proved the previous version could
      // not see this: deleting `setState(() => _formattedLocation = label)` —
      // fetching the label and throwing it away — left all 973 tests green,
      // because asserting on `geo.calls` only proves a request was made.
      // Read off ReachActionButtons, which the sheet hands the label to and
      // which carries it into "add to favourites" and the share sheet. The
      // Details disclosure that also shows it is collapsed by default and its
      // rows are not built, so there is no rendered text to match — this is the
      // consumer that is always in the tree.
      final actions = t.widget<ReachActionButtons>(
          find.byType(ReachActionButtons));
      expect(actions.formattedLocation, 'Provo, UT',
          reason: 'a label fetched and dropped is the same as no label; '
              'asserting on geo.calls alone proved only that a request went '
              'out, and deleting the setState left 973 tests green');
    });

    testWidgets('a geocode returning nothing leaves a usable sheet', (t) async {
      final geo = _FakeGeocoder(label: null);
      _register(_RecordingRepo(), geocoder: geo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(find.text('White River'), findsOneWidget);
      expect(find.textContaining('Failed to load'), findsNothing,
          reason: 'the place name is decoration; losing it is not a failure');
    });
  });

  group('guard 6 — the error card is terminal, not premature', () {
    // REGRESSION: markSettled's `settled < 3` could be changed to `< 1` and
    // every test passed — an error card thrown up over reads still in flight
    // was invisible to the suite.
    testWidgets('no error card while a read is still outstanding', (t) async {
      final repo = _RecordingRepo(
        delays: {ForecastProduct.returnPeriods: const Duration(seconds: 30)},
        failures: {
          ForecastProduct.reachMetadata,
          ForecastProduct.currentFlow,
        },
      );
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await t.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('Failed to load'), findsNothing,
          reason: 'two reads failed but the third is still in flight — '
              'declaring failure now is premature');

      await t.pump(const Duration(seconds: 31));
      await _settle(t);
    });
  });

  group('the geocode stays off the critical path AT THE CONSUMER', () {
    // REGRESSION: the only geocode guard asserted against NwmDataSource, which
    // by design never geocodes. The geocode lives at the consumer, so moving it
    // in front of the river name passed every test. In production that puts a
    // 30 s-bounded hop ahead of the title.
    testWidgets('the name renders while the geocode is still outstanding',
        (t) async {
      final geo = _FakeGeocoder(delay: const Duration(seconds: 20));
      _register(_RecordingRepo(), geocoder: geo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await t.pump(const Duration(milliseconds: 300));

      expect(find.text('White River'), findsOneWidget,
          reason: 'a place label must never gate the river name');

      await t.pump(const Duration(seconds: 21));
      await _settle(t);
    });
  });

  group('the sheet reads through the cache, never around it', () {
    // REGRESSION: swapping read() for refresh() left the suite green.
    testWidgets('no read is issued as a forced refresh', (t) async {
      final repo = _RecordingRepo();
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(repo.refreshed, isEmpty,
          reason: 'refresh() bypasses the cache — every tap becomes three '
              'network fetches and "See forecast" repeats the whole wait');
      expect(repo.requested, hasLength(3));
    });
  });

  group('a decoded-null flow is named, not silently dropped', () {
    // REGRESSION: deleting `_failedProducts.add('current flow')` from the
    // null-decode branch passed everything — guard 6's naming test drives
    // failures through catchError, never through "upstream answered 200 with a
    // body we cannot use".
    testWidgets('an unusable flow payload is named in the error card',
        (t) async {
      final repo = _RecordingRepo(failures: {
        ForecastProduct.reachMetadata,
        ForecastProduct.returnPeriods,
      }, undecodableFlow: true);
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(find.textContaining('current flow'), findsOneWidget,
          reason: 'a 200 with an unusable body is a failure of that product');
    });
  });

  group('GEOGLOWS — the branch review found untested', () {
    testWidgets('a failed load is terminal: named, retryable, not spinning',
        (t) async {
      final repo = _RecordingRepo(failures: {ForecastProduct.geoglowsForecast});
      _register(repo);

      await t.pumpWidget(
          _wrap(ReachDetailsBottomSheet(selectedReach: _geoglowsReach())));
      await _settle(t);

      expect(find.textContaining('GEOGLOWS'), findsOneWidget,
          reason: 'the failure must be named');
      expect(find.text('Retry'), findsOneWidget);
      // REGRESSION: deleting the loading resets from this branch passed the
      // whole suite. With them stuck true the sheet shows an error card over a
      // live spinner AND the header close button is replaced by that spinner,
      // so it cannot be dismissed.
      expect(find.byType(CupertinoActivityIndicator), findsNothing,
          reason: 'an error card over a live spinner is not terminal');
    });

    testWidgets('reads through the cache, never as a forced refresh',
        (t) async {
      final repo = _RecordingRepo();
      _register(repo);

      await t.pumpWidget(
          _wrap(ReachDetailsBottomSheet(selectedReach: _geoglowsReach())));
      await _settle(t);

      expect(repo.refreshed, isEmpty);
      expect(repo.requested, contains(ForecastProduct.geoglowsForecast));
      expect(repo.requested, isNot(contains(ForecastProduct.reachSummary)));
    });

    testWidgets('a GEOGLOWS tap never fetches the 156 KB series', (t) async {
      final repo = _RecordingRepo();
      _register(repo);

      await t.pumpWidget(
          _wrap(ReachDetailsBottomSheet(selectedReach: _geoglowsReach())));
      await _settle(t);

      expect(repo.requested, isNot(contains(ForecastProduct.mediumRange)));
      expect(repo.requested, isNot(contains(ForecastProduct.longRange)));
    });
  });

  group('the flood category — half of what the sheet exists to say', () {
    // REGRESSION: making recomputeCategory a no-op left the whole suite green,
    // and so did dropping it from only the thresholds handler — which is the
    // EXPECTED arrival order, since return periods (1.0-9.1 s) usually land
    // after current flow (2.1 s). The common case was unguarded.
    testWidgets('category appears when thresholds land AFTER flow', (t) async {
      final repo = _RecordingRepo(delays: {
        ForecastProduct.returnPeriods: const Duration(milliseconds: 400),
      });
      int? recolour;
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(
        selectedReach: _reach(),
        onFlowCategoryColor: (argb) => recolour = argb,
      )));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 600));
      await _settle(t);

      // The category is conveyed by colour rather than a text label, so the
      // recolour callback is the observable. It fires from recomputeCategory,
      // which is exactly what the surviving mutation neutered.
      expect(recolour, isNotNull,
          reason: 'the map recolours from this callback; silence means the '
              'stream keeps a colour the sheet is not explaining');
    });

    testWidgets('category appears when flow lands AFTER thresholds', (t) async {
      final repo = _RecordingRepo(delays: {
        ForecastProduct.currentFlow: const Duration(milliseconds: 400),
      });
      int? recolour;
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(
        selectedReach: _reach(),
        onFlowCategoryColor: (argb) => recolour = argb,
      )));
      await t.pump(const Duration(milliseconds: 600));
      await _settle(t);

      expect(recolour, isNotNull,
          reason: 'whichever value arrives second must complete the category');
    });
  });

  // REGRESSION (round 13): the sheet's category tests asserted only that the
  // recolour callback fired, so hardcoding FlowClassification.category to
  // 'Normal' left all 973 tests green — on both branches. This surface feeds
  // the map's stream recolouring, and it was the one without a value assertion.
  //
  // Colour rather than text, because that is how the sheet conveys the
  // category. Comparing two fixtures rather than pinning a palette value: same
  // 1,234 CFS flow, thresholds 100× apart, so the two must differ. This dies
  // for a classifier stuck on any one answer, and it also pins the CMS→display
  // conversion — unconverted, the 100 CMS threshold reads as 100 CFS, 1,234
  // clears it, and the "normal" fixture paints as a flood like the other.
  testWidgets('an elevated flow does not colour the same as a normal one',
      (t) async {
    int? normal;
    _register(_RecordingRepo());
    await t.pumpWidget(_wrap(ReachDetailsBottomSheet(
      selectedReach: _reach(),
      onFlowCategoryColor: (argb) => normal = argb,
    )));
    await _settle(t);
    await t.pumpWidget(_wrap(const SizedBox.shrink()));
    await GetIt.instance.reset();

    int? elevated;
    _register(_RecordingRepo(lowThresholds: true));
    await t.pumpWidget(_wrap(ReachDetailsBottomSheet(
      selectedReach: _reach(),
      onFlowCategoryColor: (argb) => elevated = argb,
    )));
    await _settle(t);

    expect(normal, isNotNull);
    expect(elevated, isNotNull);
    expect(elevated, isNot(normal),
        reason: 'same flow, thresholds 100× apart — a classifier that always '
            'answers Normal paints both identically and the map lies');
  });

  // REGRESSION (round 14): the comparison above only built NWM fixtures, so
  // hardcoding the GEOGLOWS branch's category to 'Normal' — the exact mutation
  // named in that line's own comment — left all 980 tests green. This branch
  // recolours the map for every non-US river.
  testWidgets(
      'GEOGLOWS: an elevated flow does not colour the same as a normal one',
      (t) async {
    int? normal;
    _register(_RecordingRepo());
    await t.pumpWidget(_wrap(ReachDetailsBottomSheet(
      selectedReach: _geoglowsReach(),
      onFlowCategoryColor: (argb) => normal = argb,
    )));
    await _settle(t);
    await t.pumpWidget(_wrap(const SizedBox.shrink()));
    await GetIt.instance.reset();

    int? elevated;
    _register(_RecordingRepo(lowThresholds: true));
    await t.pumpWidget(_wrap(ReachDetailsBottomSheet(
      selectedReach: _geoglowsReach(),
      onFlowCategoryColor: (argb) => elevated = argb,
    )));
    await _settle(t);

    expect(normal, isNotNull);
    expect(elevated, isNotNull);
    expect(elevated, isNot(normal),
        reason: 'same median, thresholds 100× apart — a branch hardcoded to '
            'Normal paints both identically');
  });

  group('closing mid-flight does not crash', () {
    // Closing a sheet while three <=30 s reads are outstanding is the ordinary
    // map interaction; setState after dispose throws. Every _isCancelled /
    // mounted check was deletable with the suite green.
    testWidgets('disposing while reads are outstanding is safe', (t) async {
      final repo = _RecordingRepo(delays: {
        ForecastProduct.reachMetadata: const Duration(seconds: 5),
        ForecastProduct.currentFlow: const Duration(seconds: 5),
        ForecastProduct.returnPeriods: const Duration(seconds: 5),
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await t.pump(const Duration(milliseconds: 50));

      // Sheet goes away while everything is still in flight.
      await t.pumpWidget(_wrap(const SizedBox.shrink()));
      await t.pump(const Duration(seconds: 6));
      await _settle(t);

      expect(t.takeException(), isNull,
          reason: 'a setState after dispose would surface here');
    });

    // The test above pops DURING the reads, so `_fillPlaceLabel` never starts
    // and the geocode callback's own mounted check is never exercised. Review
    // round 11 found this hole on the weekly outlook; it is the same here and
    // on both forecast-page branches. This lets the metadata land, then pops
    // while the geocode is still in flight.
    testWidgets('disposing while the place-label geocode is outstanding is safe',
        (t) async {
      _register(_RecordingRepo(),
          geocoder: _FakeGeocoder(delay: const Duration(seconds: 5)));

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      await t.pumpWidget(_wrap(const SizedBox.shrink()));
      await t.pump(const Duration(seconds: 6));
      await _settle(t);

      expect(t.takeException(), isNull,
          reason: 'the geocode resolves after dispose and its callback calls '
              'setState — only the mounted check stops that throwing');
    });
  });

  // REGRESSION (round 12, class g): the sheet resolved its dependencies inside
  // the load methods, so a missing registration was caught and rendered as a
  // load failure with a Retry that could never succeed. Fixed on the Weekly
  // Outlook in round 11 and left live here.
  // REGRESSION (round 13): every dispose test popped while a load was
  // SUCCEEDING, so the `mounted` check on the failure path was unfalsifiable —
  // on all four surfaces at once. Closing the sheet while a failing read is in
  // flight is just as ordinary as closing it during a slow one.
  group('closing mid-FAILURE does not crash', () {
    testWidgets('disposing while all three reads are failing is safe',
        (t) async {
      _register(_RecordingRepo(
        delays: {
          ForecastProduct.reachMetadata: const Duration(seconds: 5),
          ForecastProduct.currentFlow: const Duration(seconds: 5),
          ForecastProduct.returnPeriods: const Duration(seconds: 5),
        },
        failures: {
          ForecastProduct.reachMetadata,
          ForecastProduct.currentFlow,
          ForecastProduct.returnPeriods,
        },
      ));

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await t.pump(const Duration(milliseconds: 50));

      await t.pumpWidget(_wrap(const SizedBox.shrink()));
      await t.pump(const Duration(seconds: 6));
      await _settle(t);

      expect(t.takeException(), isNull,
          reason: 'markSettled writes the error card; without its mounted '
              'check that setState lands on a defunct State');
    });

    testWidgets('disposing while a failing GEOGLOWS read is outstanding is safe',
        (t) async {
      _register(_RecordingRepo(
        delays: {ForecastProduct.geoglowsForecast: const Duration(seconds: 5)},
        failures: {ForecastProduct.geoglowsForecast},
      ));

      await t.pumpWidget(
          _wrap(ReachDetailsBottomSheet(selectedReach: _geoglowsReach())));
      await t.pump(const Duration(milliseconds: 50));

      await t.pumpWidget(_wrap(const SizedBox.shrink()));
      await t.pump(const Duration(seconds: 6));
      await _settle(t);

      expect(t.takeException(), isNull);
    });
  });

  group('a missing registration is a wiring bug, not a load failure', () {
    testWidgets('NWM branch', (t) async {
      _register(_RecordingRepo());
      GetIt.instance.unregister<IRiverDataRepository>();

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      final thrown = t.takeException();
      await _settle(t);

      expect(thrown, isNotNull,
          reason: 'an unresolvable dependency must surface where it happened');
      expect(find.textContaining('Failed to load'), findsNothing);
    });

    testWidgets('the geocoder counts too', (t) async {
      _register(_RecordingRepo());
      GetIt.instance.unregister<IGeocodingService>();

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      final thrown = t.takeException();
      await _settle(t);

      expect(thrown, isNotNull,
          reason: 'round 15: the geocoder was still resolved inside a caught '
              'future here, degrading a wiring bug to a debug log');
    });

    testWidgets('GEOGLOWS branch', (t) async {
      _register(_RecordingRepo());
      GetIt.instance.unregister<IRiverDataRepository>();

      await t.pumpWidget(
          _wrap(ReachDetailsBottomSheet(selectedReach: _geoglowsReach())));
      final thrown = t.takeException();
      await _settle(t);

      expect(thrown, isNotNull);
      expect(find.textContaining('Could not load GEOGLOWS'), findsNothing);
    });
  });

  group('the no-flow terminal state', () {
    // REGRESSION: deleting the no-flow card passed everything, including
    // guard 6's own "flow fails but identity succeeds" test, which asserts
    // only an absence.
    testWidgets('a reach with no flow says so', (t) async {
      final repo = _RecordingRepo(failures: {
        ForecastProduct.currentFlow,
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(find.textContaining('not available'), findsOneWidget,
          reason: 'the user must be told why there is no number');
      // With a way out (round 16, F51): a missing flow is often transient (the
      // 2026-08-22 outage), and this card was a dead end.
      expect(find.text('Retry'), findsOneWidget);
    });

    // REGRESSION (round 17, F52): `_failedProducts` is a field, and the
    // `.clear()` at the top of each load was deletable with the suite green.
    // Without it, failure names LEAK ACROSS RETRIES: a product that failed on
    // attempt 1 but answered fine on attempt 2 is still named in attempt 2's
    // error card — guard 6's "names what failed" telling a lie.
    testWidgets('a retry does not inherit the previous attempt\'s failures',
        (t) async {
      // Attempt 1: thresholds throw (and flow is undecodable) → no-flow card.
      final repo = _RecordingRepo(
        failures: {ForecastProduct.returnPeriods},
        undecodableFlow: true,
      );
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);
      expect(find.text('Retry'), findsWidgets,
          reason: 'precondition: attempt 1 left a retryable state');

      // Attempt 2, same repo instance (the sheet resolved it in initState):
      // metadata now throws instead; thresholds answer, but with a body that
      // decodes to null — neither a success nor a named failure.
      repo.failures = {ForecastProduct.reachMetadata};
      repo.undecodableThresholds = true;

      await t.tap(find.text('Retry').first);
      await _settle(t);

      expect(find.textContaining('flood risk'), findsNothing,
          reason: 'thresholds answered fine on THIS attempt — naming them '
              'means the failure set leaked across the retry');
      expect(find.textContaining('name'), findsOneWidget,
          reason: 'and the product that did fail this attempt is named');
    });

    testWidgets('Retry from the no-flow card actually refetches', (t) async {
      final repo = _RecordingRepo(failures: {
        ForecastProduct.currentFlow,
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);
      final before = repo.requested.length;

      await t.tap(find.text('Retry'));
      await _settle(t);

      expect(repo.requested.length, greaterThan(before),
          reason: 'a Retry that issues no reads is decoration');
    });
  });

  group('GEOGLOWS — success path and dispose, swept from the NWM branch', () {
    testWidgets('a successful GEOGLOWS load renders its value', (t) async {
      _register(_RecordingRepo());

      await t.pumpWidget(
          _wrap(ReachDetailsBottomSheet(selectedReach: _geoglowsReach())));
      await _settle(t);

      expect(find.textContaining('Failed'), findsNothing);
      expect(find.textContaining('800'), findsWidgets,
          reason: 'the branch had three tests and all ran the error path');
    });

    testWidgets('disposing mid-flight on the GEOGLOWS branch is safe',
        (t) async {
      final repo = _RecordingRepo(delays: {
        ForecastProduct.geoglowsForecast: const Duration(seconds: 5),
      });
      _register(repo);

      await t.pumpWidget(
          _wrap(ReachDetailsBottomSheet(selectedReach: _geoglowsReach())));
      await t.pump(const Duration(milliseconds: 50));

      await t.pumpWidget(_wrap(const SizedBox.shrink()));
      await t.pump(const Duration(seconds: 6));
      await _settle(t);

      expect(t.takeException(), isNull);
    });
  });

}
