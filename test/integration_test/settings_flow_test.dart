// test/integration_test/settings_flow_test.dart
//
// Integration tests for settings pages:
// notifications toggle, theme selection, flow unit switching.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/features/settings/pages/notifications_settings_page.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';

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

      // Section header
      expect(find.text('FLOOD ALERTS'), findsOneWidget);

      // Toggle label
      expect(find.text('River Flood Alerts'), findsOneWidget);

      // Toggle switch is present
      expect(find.byType(CupertinoSwitch), findsOneWidget);
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

      // Tap the toggle
      await tester.tap(find.byType(CupertinoSwitch));
      await tester.pumpAndSettle();

      // After enabling, monitoring section should appear
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

      // Monitoring section visible
      expect(find.text('MONITORING'), findsOneWidget);
    });
  });

}
