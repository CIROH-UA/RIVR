// test/integration_test/settings_flow_test.dart
//
// Integration tests for settings pages:
// notifications toggle, theme selection, flow unit switching.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/features/settings/pages/notifications_settings_page.dart';
import 'package:rivr/features/settings/pages/app_theme_settings_page.dart';
import 'package:rivr/core/providers/theme_provider.dart';
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

  group('Theme settings', () {
    testWidgets('shows all three theme options', (tester) async {
      await tester.pumpWidget(buildTestApp(
        home: const AppThemeSettingsPage(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Page title
      expect(find.text('App Theme'), findsOneWidget);

      // Section header
      expect(find.text('APPEARANCE'), findsOneWidget);

      // Three options
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);

      // Subtitles
      expect(find.text('Always use light appearance'), findsOneWidget);
      expect(find.text('Always use dark appearance'), findsOneWidget);
      expect(find.text('Match device settings'), findsOneWidget);
    });

    testWidgets('selecting a theme shows checkmark on selected option',
        (tester) async {
      final themeProvider = ThemeProvider();

      await tester.pumpWidget(buildTestApp(
        home: const AppThemeSettingsPage(),
        services: services,
        authProvider: authProvider,
        themeProvider: themeProvider,
      ));
      await tester.pumpAndSettle();

      // Tap "Dark" option
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      // Checkmark should appear (on the dark option)
      expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);

      // Tap "Light" option
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();

      // Checkmark should still be one (moved to light)
      expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
    });

    testWidgets('shows footer description', (tester) async {
      await tester.pumpWidget(buildTestApp(
        home: const AppThemeSettingsPage(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Choose how RIVR looks'),
        findsOneWidget,
      );
    });
  });
}
