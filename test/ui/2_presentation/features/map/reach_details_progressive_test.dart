// test/ui/2_presentation/features/map/reach_details_progressive_test.dart
//
// ADR 0011 Phase 1 guards — the map detail sheet renders progressively.
//
// What this exists to prevent: the sheet used to make ONE `reachSummary` read,
// which looked cheap at the call site and was not. Building that payload fetched
// reach info, current flow, return periods AND a medium-range forecast
// serially — ~45 s at median, of which the 156 KB / 30.8 s medium-range call was
// the bulk. The sheet never rendered a forecast series at all; its peak comes
// from the map tile.
//
// Guard 3 ("medium range is never requested") is the one that would catch a
// regression to that design, and it FAILS against the previous implementation —
// which requested `reachSummary`, whose fetch pulls medium range internally.

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_details_bottom_sheet.dart';

// ── Fakes ────────────────────────────────────────────────────────────────────

class _StubUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
  @override
  double convertFlow(double value, String from, String to) => value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Returns a fixed current flow regardless of payload — the extraction itself
/// is ForecastService's job and is covered by its own tests.
class _StubForecastService implements IForecastService {
  @override
  double? getCurrentFlow(ForecastResponse forecast, {String? preferredType}) =>
      1234.0;
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
  _RecordingRepo({this.delays = const {}, this.failures = const {}});

  /// product -> how long its read takes.
  final Map<ForecastProduct, Duration> delays;

  /// products whose read should throw.
  final Set<ForecastProduct> failures;

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

  static Map<String, dynamic> _payloadFor(ForecastProduct p) {
    switch (p) {
      case ForecastProduct.reachMetadata:
        return {
          'riverName': 'White River',
          'formattedLocation': 'Provo, UT',
          'latitude': 40.2,
          'longitude': -111.6,
        };
      case ForecastProduct.returnPeriods:
        // Shape mirrors the real API: one object per reach with
        // `return_period_<years>` keys (see ReachDataDto.fromReturnPeriodApi).
        return {
          'returnPeriods': [
            {
              'feature_id': '9962444',
              'return_period_2': 100.0,
              'return_period_5': 200.0,
            },
          ],
        };
      case ForecastProduct.analysisAssimilation:
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
          'shortRange': <String, dynamic>{},
        };
      default:
        return <String, dynamic>{};
    }
  }

  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) => read(key);
  @override
  ValueListenable<RiverDataEntry?> watch(RiverDataKey key) =>
      ValueNotifier(null);
  @override
  Future<void> ingest(RiverDataEntry e) async {}
}

SelectedReach _reach() => SelectedReach(
      reachId: '9962444',
      source: ForecastSource.nwm,
      streamOrder: 4,
      latitude: 40.2,
      longitude: -111.6,
      selectedAt: DateTime.utc(2026, 8, 22, 12),
    );

void _register(_RecordingRepo repo) {
  final sl = GetIt.instance;
  sl.registerSingleton<IRiverDataRepository>(repo);
  sl.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
  sl.registerSingleton<IForecastService>(_StubForecastService());
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
        ForecastProduct.analysisAssimilation: const Duration(seconds: 30),
        ForecastProduct.returnPeriods: const Duration(seconds: 30),
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await t.pump();

      expect(find.byType(ReachDetailsBottomSheet), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsWidgets,
          reason: 'a skeleton, not a blank sheet');
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
      // products. reachSummary is warmed afterwards for the forecast page and
      // is covered by guard 5.
      final blocking = repo.requested.take(3).toSet();
      expect(blocking, {
        ForecastProduct.reachMetadata,
        ForecastProduct.analysisAssimilation,
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
        ForecastProduct.analysisAssimilation,
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
        ForecastProduct.analysisAssimilation: const Duration(milliseconds: 40),
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
        ForecastProduct.analysisAssimilation: const Duration(seconds: 30),
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
        ForecastProduct.analysisAssimilation: const Duration(milliseconds: 20),
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
        ForecastProduct.analysisAssimilation,
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
        ForecastProduct.analysisAssimilation,
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
    });

    testWidgets('Retry re-issues the reads', (t) async {
      final repo = _RecordingRepo(failures: {
        ForecastProduct.reachMetadata,
        ForecastProduct.analysisAssimilation,
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
}
