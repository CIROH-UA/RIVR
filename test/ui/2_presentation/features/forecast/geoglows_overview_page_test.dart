// test/ui/2_presentation/features/forecast/geoglows_overview_page_test.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/ui/2_presentation/features/forecast/pages/geoglows_overview_page.dart';

/// Fake repository returning a GEOGLOWS forecast entry (or throwing), so the
/// page is tested without network/DI plumbing.
class _FakeRepo implements IRiverDataRepository {
  _FakeRepo({this.fail = false});
  final bool fail;

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    if (fail) throw Exception('boom');
    final fc = GeoglowsForecast(
      riverId: key.reachId,
      unit: 'ft³/s',
      generatedAt: DateTime.utc(2026, 6, 25),
      points: [
        GeoglowsForecastPoint(
          validTime: DateTime.utc(2026, 6, 25, 0),
          median: 1387.9,
          lower: 1300,
          upper: 1450,
        ),
        GeoglowsForecastPoint(
          validTime: DateTime.utc(2026, 6, 26, 0),
          median: 1400,
          lower: 1350,
          upper: 1500,
        ),
      ],
    );
    return RiverDataEntry(
      key: key,
      window: FreshnessWindow(
        fetchedAt: DateTime.utc(2026, 6, 25),
        validUntil: DateTime.utc(2026, 6, 26),
      ),
      unit: 'CFS',
      payload: GeoglowsForecastPayload.encode(fc),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
  @override
  double convertFlow(double value, String from, String to) => value; // identity
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  setUp(() {
    getIt.registerSingleton<IFlowUnitPreferenceService>(_FakeUnit());
  });

  tearDown(() {
    if (getIt.isRegistered<IRiverDataRepository>()) {
      getIt.unregister<IRiverDataRepository>();
    }
    if (getIt.isRegistered<IFlowUnitPreferenceService>()) {
      getIt.unregister<IFlowUnitPreferenceService>();
    }
  });

  testWidgets('renders current flow and daily rows from a GEOGLOWS forecast',
      (tester) async {
    getIt.registerSingleton<IRiverDataRepository>(_FakeRepo());

    await tester.pumpWidget(
      const CupertinoApp(home: GeoglowsOverviewPage(reachId: '210066600')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Stream 210066600'), findsOneWidget);
    expect(find.text('Flowing now'), findsOneWidget);
    expect(find.text('1388'), findsOneWidget); // 1387.9 -> "1388"
    expect(find.text('NEXT 15 DAYS · DAILY MEDIAN'), findsOneWidget);
  });

  testWidgets('shows an error state with retry when the fetch fails',
      (tester) async {
    getIt.registerSingleton<IRiverDataRepository>(_FakeRepo(fail: true));

    await tester.pumpWidget(
      const CupertinoApp(home: GeoglowsOverviewPage(reachId: '999')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not load'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
