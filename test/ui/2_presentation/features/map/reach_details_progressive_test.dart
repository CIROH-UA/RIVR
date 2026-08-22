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

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    requested.add(key.product);
    final d = delays[key.product];
    if (d != null) await Future<void>.delayed(d);
    if (failures.contains(key.product)) {
      throw Exception('simulated failure for ${key.product}');
    }
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

  group('guard 3 — the 156 KB medium-range fetch is never requested', () {
    // REGRESSION: the old sheet read `reachSummary`, whose fetch pulls medium
    // range internally. This assertion fails against that implementation.
    testWidgets('sheet requests only the three narrow products', (t) async {
      final repo = _RecordingRepo();
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(repo.requested, isNot(contains(ForecastProduct.mediumRange)),
          reason: 'the sheet renders no forecast series — it must not fetch one');
      expect(repo.requested, isNot(contains(ForecastProduct.reachSummary)),
          reason: 'reachSummary drags medium range in behind it');
      expect(repo.requested, contains(ForecastProduct.reachMetadata));
      expect(repo.requested, contains(ForecastProduct.analysisAssimilation));
      expect(repo.requested, contains(ForecastProduct.returnPeriods));
    });
  });

  group('guard 5 — the long-range prefetch never competes with first paint', () {
    testWidgets('long range is requested, but only after the sheet\'s own reads',
        (t) async {
      final repo = _RecordingRepo(delays: {
        ForecastProduct.reachMetadata: const Duration(milliseconds: 20),
        ForecastProduct.analysisAssimilation: const Duration(milliseconds: 30),
        ForecastProduct.returnPeriods: const Duration(milliseconds: 10),
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(repo.requested, contains(ForecastProduct.longRange),
          reason: '"See forecast" must not wait a second time');
      final firstThree = repo.requested.take(3).toSet();
      expect(firstThree, isNot(contains(ForecastProduct.longRange)),
          reason: 'prefetch must start after the sheet\'s own reads, not with them');
    });
  });

  group('guard 2 — values render as they land, not all at once', () {
    testWidgets('the fast value is on screen while the slow one is outstanding',
        (t) async {
      final repo = _RecordingRepo(delays: {
        // Identity is quick; flow is deliberately glacial.
        ForecastProduct.reachMetadata: const Duration(milliseconds: 50),
        ForecastProduct.analysisAssimilation: const Duration(seconds: 30),
        ForecastProduct.returnPeriods: const Duration(seconds: 30),
      });
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));

      // Past identity, nowhere near the flow calls.
      await t.pump(const Duration(milliseconds: 200));

      expect(find.text('White River'), findsOneWidget,
          reason: 'the river is named while flow is still 30s away');

      await t.pump(const Duration(seconds: 31));
      await _settle(t);
    });
  });

  group('guard 4 — a failed prefetch is silent', () {
    testWidgets('long-range failure surfaces no error and does not break the sheet',
        (t) async {
      final repo = _RecordingRepo(failures: {ForecastProduct.longRange});
      _register(repo);

      await t.pumpWidget(_wrap(ReachDetailsBottomSheet(selectedReach: _reach())));
      await _settle(t);

      expect(find.text('White River'), findsOneWidget);
      expect(find.textContaining('Failed to load'), findsNothing,
          reason: '2 of 9 long-range calls 504d while measuring — a prefetch '
              'failure must cost the user nothing');
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
    });
  });
}
