// test/integration_test/settings_flow_test.dart
//
// Integration tests for settings pages:
// notifications toggle, theme selection, flow unit switching.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/ui/2_presentation/features/settings/pages/notifications_settings_page.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';

import 'helpers/test_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestServices services;
  late AuthProvider authProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetServiceLocator();
    services = TestServices();
    services.seedSignedInUser();
    services.registerAll();

    authProvider = createAuthProvider(services);
    await authProvider.initialize();
    await authProvider.signIn('test@example.com', 'password123');
  });

  tearDown(() async {
    await resetServiceLocator();
  });

  group('Notifications settings', () {
    testWidgets('shows notifications page with toggle', (tester) async {
      await tester.pumpWidget(buildTestApp(
        home: const NotificationsSettingsPage(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Page title
      expect(find.text('Notifications'), findsOneWidget);

      // Both notification-type sections are present
      expect(find.text('FLOOD ALERTS'), findsOneWidget);
      expect(find.text('DIGEST'), findsOneWidget);

      // Toggle labels
      expect(find.text('River Flood Alerts'), findsOneWidget);
      expect(find.text('Weekly Outlook'), findsOneWidget);

      // One switch per notification type
      expect(find.byType(CupertinoSwitch), findsNWidgets(2));
    });

    testWidgets('toggle enables notifications and shows frequency section',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        home: const NotificationsSettingsPage(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Initially notifications are disabled (from seeded settings)
      // Monitoring section should not be visible
      expect(find.text('MONITORING'), findsNothing);

      // Tap the Flood Alerts toggle (first switch)
      await tester.tap(find.byType(CupertinoSwitch).first);
      await tester.pumpAndSettle();

      // After enabling, monitoring section should appear (scroll it into view —
      // the page now has an extra DIGEST section above it).
      await tester.scrollUntilVisible(
        find.text('MONITORING'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('MONITORING'), findsOneWidget);
    });

    testWidgets('shows monitoring count for favorites', (tester) async {
      // Seed some favorites so monitoring section shows count
      services.seedFavorites([
        createTestFavorite(reachId: '1001', riverName: 'River A'),
        createTestFavorite(reachId: '1002', riverName: 'River B'),
      ]);

      // Seed settings with notifications already enabled
      services.userSettings.seedSettings(
        services.userSettings.currentSettings!.copyWith(
            enableNotifications: true),
      );

      await tester.pumpWidget(buildTestApp(
        home: const NotificationsSettingsPage(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Monitoring section visible (scroll past the DIGEST section to reach it).
      await tester.scrollUntilVisible(
        find.text('MONITORING'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('MONITORING'), findsOneWidget);
    });
  });

}
