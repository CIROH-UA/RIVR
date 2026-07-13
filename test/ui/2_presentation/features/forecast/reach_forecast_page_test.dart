// test/ui/2_presentation/features/forecast/reach_forecast_page_test.dart
//
// Widget tests for the consolidated forecast page. Covers both source paths:
//  - GEOGLOWS: reads geoglowsForecast from the repository; no ReachDataProvider.
//  - NWM: reads reachSummary from the repository; a fake ReachDataProvider
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
  @override
  double convertFlow(double value, String from, String to) => value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRepo implements IRiverDataRepository {
  _FakeRepo(this.entry);
  final RiverDataEntry? entry;

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async => entry;
  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) async => entry;
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

void _registerRepo(RiverDataEntry entry) {
  final sl = GetIt.instance;
  sl.registerSingleton<IRiverDataRepository>(_FakeRepo(entry));
  sl.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
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
    _registerRepo(RiverDataEntry(
      key: const RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '123',
        product: ForecastProduct.reachSummary,
      ),
      window: _window(),
      unit: 'CFS',
      payload: ReachSummaryPayload.encode(details),
    ));

    await tester.pumpWidget(_wrap(const ReachForecastPage(
      reachId: '123',
      source: ForecastSource.nwm,
    )));
    await _pumpLoaded(tester);

    expect(find.text('640 ft³/s', findRichText: true), findsOneWidget);
    expect(find.text('NORMAL'), findsOneWidget);
    expect(find.text('Test River'), findsOneWidget);
    expect(find.text('Testville, TS'), findsOneWidget);
    // Range selector: Today + the two multi-day options (nominal while the
    // separate forecast series hasn't loaded in this fake).
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('10D'), findsOneWidget);
    expect(find.text('30D'), findsOneWidget);
  });
}
