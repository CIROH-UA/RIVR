// test/integration_test/forecast_flow_test.dart
//
// Integration tests for the forecast/reach overview flow:
// progressive loading, data display, error/timeout states, navigation.
//
// NOTE: ReachOverviewPage starts a 30-second timeout future, so
// pumpAndSettle() will never return. All tests use pump() with
// explicit durations to advance past async loading phases.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/features/forecast/pages/reach_overview_page.dart';
import 'package:rivr/core/providers/reach_data_provider.dart';

import 'helpers/test_app.dart';

/// Pump enough frames for the mock forecast service (50ms delay) to resolve
/// and for the UI to rebuild after each loading phase.
Future<void> pumpUntilLoaded(WidgetTester tester) async {
  // Phase 1: overview data
  await tester.pump(const Duration(milliseconds: 200));
  // Phase 2: hourly, daily, extended forecasts (each 50ms + 100ms gap)
  await tester.pump(const Duration(milliseconds: 500));
  // Phase 3: supplementary data
  await tester.pump(const Duration(milliseconds: 200));
  // Final rebuild
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestServices services;
  late ReachDataProvider reachDataProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetServiceLocator();
    services = TestServices();
    services.seedSignedInUser();
    services.forecast.delay = const Duration(milliseconds: 50);
    services.registerAll();
  });

  tearDown(() async {
    await resetServiceLocator();
  });

  group('Reach overview loading', () {
    testWidgets('shows loading indicator before data arrives', (tester) async {
      // Use a longer delay so loading state is visible
      services.forecast.delay = const Duration(seconds: 1);
      reachDataProvider = createReachDataProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const ReachOverviewPage(reachId: '23021904'),
        services: services,
        reachDataProvider: reachDataProvider,
      ));

      // First frame - trigger postFrameCallback
      await tester.pump();
      // Second pump - loading should now be visible
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Loading river overview...'), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsAtLeast(1));
    });

    testWidgets('displays river name and location after loading',
        (tester) async {
      reachDataProvider = createReachDataProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const ReachOverviewPage(reachId: '23021904'),
        services: services,
        reachDataProvider: reachDataProvider,
      ));
      await tester.pump(); // trigger postFrameCallback
      await pumpUntilLoaded(tester);

      // River name should be displayed
      expect(find.text('Deep Creek'), findsAtLeast(1));

      // Nav bar title
      expect(find.text('Flow Forecast Overview'), findsOneWidget);
    });

    testWidgets('shows station information section', (tester) async {
      reachDataProvider = createReachDataProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const ReachOverviewPage(reachId: '23021904'),
        services: services,
        reachDataProvider: reachDataProvider,
      ));
      await tester.pump();
      await pumpUntilLoaded(tester);

      // Station info section (may be below the fold depending on viewport)
      expect(find.text('Station Information', skipOffstage: false), findsOneWidget);
      expect(find.text('Data Source', skipOffstage: false), findsOneWidget);
      expect(find.text('NOAA National Water Model', skipOffstage: false), findsOneWidget);
    });

    testWidgets('shows forecast categories heading', (tester) async {
      reachDataProvider = createReachDataProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const ReachOverviewPage(reachId: '23021904'),
        services: services,
        reachDataProvider: reachDataProvider,
      ));
      await tester.pump();
      await pumpUntilLoaded(tester);

      expect(find.text('Forecast Categories', skipOffstage: false), findsOneWidget);
    });
  });

  group('Error states', () {
    testWidgets('shows error state when loading fails', (tester) async {
      services.forecast.shouldFail = true;
      services.forecast.failureMessage = 'Network error';
      reachDataProvider = createReachDataProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const ReachOverviewPage(reachId: '23021904'),
        services: services,
        reachDataProvider: reachDataProvider,
      ));
      await tester.pump();
      await pumpUntilLoaded(tester);

      // Error state visible
      expect(find.text('Unable to Load River Data'), findsOneWidget);
      expect(find.text('Try Again'), findsOneWidget);
    });

    testWidgets('retry button works after error', (tester) async {
      services.forecast.shouldFail = true;
      reachDataProvider = createReachDataProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const ReachOverviewPage(reachId: '23021904'),
        services: services,
        reachDataProvider: reachDataProvider,
      ));
      await tester.pump();
      await pumpUntilLoaded(tester);

      // Should show error
      expect(find.text('Unable to Load River Data'), findsOneWidget);

      // Fix the service and retry
      services.forecast.shouldFail = false;
      await tester.tap(find.text('Try Again'));
      await tester.pump();
      await pumpUntilLoaded(tester);

      // Should now show data
      expect(find.text('Deep Creek'), findsAtLeast(1));
    });

    testWidgets('shows fallback title when reachId is null', (tester) async {
      reachDataProvider = createReachDataProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const ReachOverviewPage(reachId: null),
        services: services,
        reachDataProvider: reachDataProvider,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('River Forecast'), findsOneWidget);
    });
  });

  group('Refresh', () {
    testWidgets('refresh button is present in nav bar', (tester) async {
      reachDataProvider = createReachDataProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const ReachOverviewPage(reachId: '23021904'),
        services: services,
        reachDataProvider: reachDataProvider,
      ));
      await tester.pump();
      await pumpUntilLoaded(tester);

      // Refresh icon should be in the nav bar
      expect(find.byIcon(CupertinoIcons.refresh), findsOneWidget);
    });
  });

  group('Technical info', () {
    testWidgets('reach ID is present in widget tree after loading',
        (tester) async {
      reachDataProvider = createReachDataProvider(services);

      await tester.pumpWidget(buildTestApp(
        home: const ReachOverviewPage(reachId: '23021904'),
        services: services,
        reachDataProvider: reachDataProvider,
      ));
      await tester.pump();
      await pumpUntilLoaded(tester);

      // The reach ID value should exist in the widget tree (even if
      // the chip is off-screen, it's in the sliver list). Use
      // skipOffstage: false to find it regardless of scroll position.
      expect(
        find.text('23021904', skipOffstage: false),
        findsAtLeast(1),
      );
    });
  });
}
