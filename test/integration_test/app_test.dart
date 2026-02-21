// test/integration_test/app_test.dart
//
// Smoke test verifying the test infrastructure works.
// Full integration test suites are in separate files:
//
//   flutter test test/integration_test/auth_flow_test.dart
//   flutter test test/integration_test/favorites_flow_test.dart
//   flutter test test/integration_test/forecast_flow_test.dart
//   flutter test test/integration_test/settings_flow_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/features/auth/presentation/pages/auth_wrapper.dart';
import 'package:rivr/features/auth/presentation/pages/login_page.dart';

import 'helpers/test_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestServices services;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetServiceLocator();
    services = TestServices();
    services.registerAll();
  });

  tearDown(() async {
    await resetServiceLocator();
  });

  testWidgets('app launches to login screen', (tester) async {
    final authProvider = createAuthProvider(services);
    await authProvider.initialize();

    await tester.pumpWidget(buildTestApp(
      home: const AuthWrapper(),
      services: services,
      authProvider: authProvider,
    ));
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('RIVR'), findsAtLeast(1));
  });
}
