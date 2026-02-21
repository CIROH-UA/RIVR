// test/integration_test/auth_flow_test.dart
//
// Integration tests for the authentication flow:
// login, registration, forgot password, page transitions, sign out.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rivr/features/auth/presentation/pages/auth_wrapper.dart';
import 'package:rivr/features/auth/presentation/pages/login_page.dart';
import 'package:rivr/features/auth/presentation/pages/register_page.dart';
import 'package:rivr/features/auth/presentation/pages/forgot_password_page.dart';
import 'package:rivr/features/auth/presentation/pages/email_verification_page.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';

import 'helpers/test_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestServices services;
  late AuthProvider authProvider;

  setUp(() async {
    await resetServiceLocator();
    services = TestServices();
    services.registerAll();
  });

  tearDown(() async {
    await resetServiceLocator();
  });

  group('Login flow', () {
    testWidgets('shows login page by default with email and password fields',
        (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Login page should be visible
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.text('Welcome to'), findsOneWidget);
      expect(find.text('RIVR'), findsAtLeast(1));
      expect(find.text('Sign In'), findsOneWidget);
      expect(find.text('Forgot Password?'), findsOneWidget);
      expect(find.text('Sign Up'), findsOneWidget);
    });

    testWidgets('successful login shows authenticated view', (tester) async {
      services.seedSignedInUser(
        email: 'john@example.com',
        password: 'password123',
        firstName: 'John',
        lastName: 'Doe',
      );
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(
          authenticatedChild: const CupertinoPageScaffold(
            child: Center(child: Text('Home Screen')),
          ),
        ),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Enter email
      final emailFields = find.byType(CupertinoTextField);
      await tester.enterText(emailFields.first, 'john@example.com');
      await tester.pumpAndSettle();

      // Enter password
      await tester.enterText(emailFields.at(1), 'password123');
      await tester.pumpAndSettle();

      // Tap Sign In
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      // Should navigate to authenticated view
      expect(find.text('Home Screen'), findsOneWidget);
    });

    testWidgets('failed login shows error message', (tester) async {
      services.auth.seedUser(
        email: 'john@example.com',
        password: 'correctPassword',
      );
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Enter wrong password
      final emailFields = find.byType(CupertinoTextField);
      await tester.enterText(emailFields.first, 'john@example.com');
      await tester.enterText(emailFields.at(1), 'wrongPassword');
      await tester.pumpAndSettle();

      // Tap Sign In
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      // Should show error
      expect(find.text('Invalid email or password'), findsOneWidget);
      // Should still be on login page
      expect(find.byType(LoginPage), findsOneWidget);
    });

    testWidgets('empty fields show validation error from provider',
        (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Tap Sign In without entering anything
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      // AuthProvider.signIn checks for empty fields
      expect(
        find.text('Please enter both email and password'),
        findsOneWidget,
      );
    });
  });

  group('Registration flow', () {
    testWidgets('navigate to register page and back', (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Tap "Sign Up" link
      await tester.tap(find.text('Sign Up'));
      await tester.pumpAndSettle();

      // Register page should be visible
      expect(find.byType(RegisterPage), findsOneWidget);
      expect(find.text('Create Account'), findsOneWidget);
      expect(find.text('Sign In'), findsOneWidget);

      // Go back to login
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      expect(find.byType(LoginPage), findsOneWidget);
    });

    testWidgets('successful registration shows email verification page',
        (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Navigate to register
      await tester.tap(find.text('Sign Up'));
      await tester.pumpAndSettle();

      // Fill in registration fields (5 CupertinoTextFields)
      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'Jane'); // First Name
      await tester.enterText(fields.at(1), 'Doe'); // Last Name
      await tester.enterText(fields.at(2), 'jane@example.com'); // Email
      await tester.enterText(fields.at(3), 'password123'); // Password
      await tester.enterText(fields.at(4), 'password123'); // Confirm Password
      await tester.pumpAndSettle();

      // Tap Create Account
      await tester.tap(find.text('Create Account'));
      await tester.pumpAndSettle();

      // Should show email verification page
      expect(find.byType(EmailVerificationPage), findsOneWidget);
      expect(find.text('Verify your email'), findsOneWidget);
    });
  });

  group('Forgot password flow', () {
    testWidgets('navigate to forgot password and send reset email',
        (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Tap "Forgot Password?"
      await tester.tap(find.text('Forgot Password?'));
      await tester.pumpAndSettle();

      // Forgot password page visible
      expect(find.byType(ForgotPasswordPage), findsOneWidget);
      expect(find.text('Reset Your Password'), findsOneWidget);
      expect(find.text('Send Reset Email'), findsOneWidget);

      // Enter email and submit
      final emailField = find.byType(CupertinoTextField);
      await tester.enterText(emailField.first, 'john@example.com');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Send Reset Email'));
      await tester.pumpAndSettle();

      // Should show success state
      expect(find.text('Email Sent!'), findsOneWidget);
    });

    testWidgets('back to sign in from forgot password page', (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Navigate to forgot password
      await tester.tap(find.text('Forgot Password?'));
      await tester.pumpAndSettle();

      // Tap "Back to Sign In"
      await tester.tap(find.text('Back to Sign In'));
      await tester.pumpAndSettle();

      // Back on login page
      expect(find.byType(LoginPage), findsOneWidget);
    });
  });

  group('Email verification flow', () {
    testWidgets('verification page shows after registration', (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(
          authenticatedChild: const CupertinoPageScaffold(
            child: Center(child: Text('Home Screen')),
          ),
        ),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Navigate to register
      await tester.tap(find.text('Sign Up'));
      await tester.pumpAndSettle();

      // Fill in registration
      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'Test');
      await tester.enterText(fields.at(1), 'User');
      await tester.enterText(fields.at(2), 'new@example.com');
      await tester.enterText(fields.at(3), 'password123');
      await tester.enterText(fields.at(4), 'password123');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create Account'));
      await tester.pumpAndSettle();

      // Should show verification page
      expect(find.byType(EmailVerificationPage), findsOneWidget);
      expect(find.text("I've Verified My Email"), findsOneWidget);
      expect(find.text('Resend Verification Email'), findsOneWidget);
      expect(find.text('Use a different email'), findsOneWidget);
    });

    testWidgets('successful email verification navigates to authenticated view',
        (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(
          authenticatedChild: const CupertinoPageScaffold(
            child: Center(child: Text('Home Screen')),
          ),
        ),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Register a new user
      await tester.tap(find.text('Sign Up'));
      await tester.pumpAndSettle();

      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'Test');
      await tester.enterText(fields.at(1), 'User');
      await tester.enterText(fields.at(2), 'verify@example.com');
      await tester.enterText(fields.at(3), 'password123');
      await tester.enterText(fields.at(4), 'password123');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create Account'));
      await tester.pumpAndSettle();

      // Now on verification page - simulate server-side verification
      services.auth.simulateEmailVerification();

      // Tap "I've Verified My Email"
      await tester.tap(find.text("I've Verified My Email"));
      await tester.pumpAndSettle();

      // Should navigate to authenticated view
      expect(find.text('Home Screen'), findsOneWidget);
    });
  });

  group('Auth page transitions', () {
    testWidgets('login -> register -> login cycle', (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Start on login
      expect(find.byType(LoginPage), findsOneWidget);

      // Go to register
      await tester.tap(find.text('Sign Up'));
      await tester.pumpAndSettle();
      expect(find.byType(RegisterPage), findsOneWidget);

      // Go back to login
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
    });

    testWidgets('login -> forgot password -> login cycle', (tester) async {
      authProvider = createAuthProvider(services);
      await authProvider.initialize();

      await tester.pumpWidget(buildTestApp(
        home: AuthWrapper(),
        services: services,
        authProvider: authProvider,
      ));
      await tester.pumpAndSettle();

      // Go to forgot password
      await tester.tap(find.text('Forgot Password?'));
      await tester.pumpAndSettle();
      expect(find.byType(ForgotPasswordPage), findsOneWidget);

      // Go back to login
      await tester.tap(find.text('Back to Sign In'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
    });
  });
}
