// test/ui/2_presentation/features/forecast/geoglows_overview_page_test.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/ui/2_presentation/features/forecast/pages/geoglows_overview_page.dart';

class _FakeGeoglowsApi implements IGeoglowsApiService {
  final bool fail;
  _FakeGeoglowsApi({this.fail = false});

  @override
  Future<GeoglowsForecast> fetchForecast(String riverId) async {
    if (fail) throw Exception('boom');
    return GeoglowsForecast(
      riverId: riverId,
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
  }

  @override
  Future<GeoglowsEnsembleForecast> fetchEnsembleStats(String riverId) async =>
      throw UnimplementedError();
}

void main() {
  final getIt = GetIt.instance;

  tearDown(() {
    if (getIt.isRegistered<IGeoglowsApiService>()) {
      getIt.unregister<IGeoglowsApiService>();
    }
  });

  testWidgets('renders current flow and daily rows from a GEOGLOWS forecast',
      (tester) async {
    getIt.registerSingleton<IGeoglowsApiService>(_FakeGeoglowsApi());

    await tester.pumpWidget(
      const CupertinoApp(home: GeoglowsOverviewPage(reachId: '210066600')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Stream 210066600'), findsOneWidget);
    expect(find.text('Flowing now'), findsOneWidget);
    // Current median 1387.9 -> formatted "1388"
    expect(find.text('1388'), findsOneWidget);
    // Two distinct local days in the fixture -> two daily rows.
    expect(find.text('NEXT 15 DAYS · DAILY MEDIAN'), findsOneWidget);
  });

  testWidgets('shows an error state with retry when the fetch fails',
      (tester) async {
    getIt.registerSingleton<IGeoglowsApiService>(_FakeGeoglowsApi(fail: true));

    await tester.pumpWidget(
      const CupertinoApp(home: GeoglowsOverviewPage(reachId: '999')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not load'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
