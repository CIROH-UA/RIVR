import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart' show MockUser;
import 'package:get_it/get_it.dart';
import 'package:rivr/core/services/i_auth_service.dart';
import 'package:rivr/core/services/auth_service.dart';
import 'package:rivr/core/services/i_user_settings_service.dart';
import 'package:rivr/core/services/i_fcm_service.dart';
import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';

// ---------------------------------------------------------------------------
// Minimal mocks for AuthProvider unit tests
// ---------------------------------------------------------------------------

class _MockAuthService implements IAuthService {
  final StreamController<fb.User?> _authStateController =
      StreamController<fb.User?>.broadcast();

  MockUser? _signedInUser;
  bool _emailVerified = false;
  final Map<String, Map<String, String>> _accounts = {};

  void seedUser({
    required String email,
    required String password,
    bool emailVerified = true,
  }) {
    _accounts[email] = {'password': password};
    _emailVerified = emailVerified;
  }

  @override
  fb.User? get currentUser => _signedInUser;

  @override
  Stream<fb.User?> get authStateChanges => _authStateController.stream;

  @override
  bool get isSignedIn => _signedInUser != null;

  @override
  Future<AuthResult> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final account = _accounts[email];
    if (account == null || account['password'] != password) {
      return AuthResult.failure('Invalid email or password');
    }
    _signedInUser = MockUser(
      uid: 'uid-${email.hashCode}',
      email: email,
      displayName: 'Test User',
      isEmailVerified: _emailVerified,
    );
    _authStateController.add(_signedInUser);
    return AuthResult.success(_signedInUser);
  }

  @override
  Future<AuthResult> registerWithEmailAndPassword({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    if (_accounts.containsKey(email)) {
      return AuthResult.failure('Email already in use');
    }
    _accounts[email] = {'password': password};
    _signedInUser = MockUser(
      uid: 'uid-${email.hashCode}',
      email: email,
      displayName: '$firstName $lastName',
      isEmailVerified: false,
    );
    _authStateController.add(_signedInUser);
    return AuthResult.success(_signedInUser);
  }

  @override
  Future<AuthResult> sendPasswordResetEmail({required String email}) async =>
      AuthResult.success(null, message: 'Sent');

  @override
  Future<AuthResult> signOut() async {
    _signedInUser = null;
    _authStateController.add(null);
    return AuthResult.success(null);
  }

  @override
  Future<bool> isBiometricAvailable() async => false;
  @override
  Future<bool> isBiometricEnabled() async => false;
  @override
  Future<AuthResult> enableBiometricLogin() async =>
      AuthResult.failure('N/A');
  @override
  Future<AuthResult> disableBiometricLogin() async =>
      AuthResult.failure('N/A');
  @override
  Future<AuthResult> signInWithBiometrics() async =>
      AuthResult.failure('N/A');
  @override
  Future<AuthResult> updateDisplayName(String displayName) async =>
      AuthResult.success(_signedInUser);
  @override
  Future<void> reloadUser() async {}
  @override
  Future<AuthResult> sendEmailVerification() async =>
      AuthResult.success(_signedInUser);
  @override
  Future<bool> checkEmailVerified() async => _emailVerified;

  void dispose() => _authStateController.close();
}

class _MockUserSettingsService implements IUserSettingsService {
  @override
  Future<UserSettings?> getUserSettings(String userId) async => null;
  @override
  Future<void> saveUserSettings(UserSettings settings) async {}
  @override
  Future<void> updateUserSettings(
      String userId, Map<String, dynamic> updates) async {}
  @override
  Future<UserSettings?> addCustomBackgroundImage(
          String userId, String imagePath) async =>
      null;
  @override
  Future<UserSettings?> removeCustomBackgroundImage(
          String userId, String imagePath) async =>
      null;
  @override
  Future<List<String>> getUserCustomBackgrounds(String userId) async => [];
  @override
  Future<UserSettings?> validateCustomBackgrounds(String userId) async => null;
  @override
  Future<UserSettings?> clearAllCustomBackgrounds(String userId) async => null;
  @override
  Future<UserSettings> createDefaultSettings({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
  }) async =>
      UserSettings(
        userId: userId,
        email: email,
        firstName: firstName,
        lastName: lastName,
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twelveHour,
        enableNotifications: false,
        favoriteReachIds: const [],
        lastLoginDate: DateTime.now(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
  @override
  Future<UserSettings?> syncAfterLogin(String userId) async => null;
  @override
  Future<UserSettings?> addFavoriteReach(
          String userId, String reachId) async =>
      null;
  @override
  Future<UserSettings?> removeFavoriteReach(
          String userId, String reachId) async =>
      null;
  @override
  Future<UserSettings?> updateFlowUnit(
          String userId, FlowUnit flowUnit) async =>
      null;
  @override
  Future<UserSettings?> updateNotifications(
          String userId, bool enableNotifications) async =>
      null;
  @override
  Future<UserSettings?> updateNotificationFrequency(
          String userId, int frequency) async =>
      null;
  @override
  void clearCache() {}
  @override
  Future<bool> userHasSettings(String userId) async => false;
  @override
  Future<void> syncFlowUnitPreference(String userId) async {}
}

class _MockFCMService implements IFCMService {
  @override
  set navigatorKey(GlobalKey<NavigatorState> key) {}
  @override
  Future<bool> initialize() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  void setupNotificationListeners() {}
  @override
  Future<String?> getAndSaveToken(String userId) async => 'mock-token';
  @override
  Future<NotificationPermissionResult> enableNotifications(
          String userId) async =>
      NotificationPermissionResult.granted;
  @override
  Future<void> disableNotifications(String userId) async {}
  @override
  Future<bool> isEnabledForUser(String userId) async => false;
  @override
  Future<void> refreshTokenIfNeeded(String userId) async {}
  @override
  void clearCache() {}
}

void main() {
  late _MockAuthService mockAuth;
  late _MockUserSettingsService mockSettings;
  late AuthProvider provider;

  setUp(() {
    // Register IFCMService in GetIt (AuthProvider uses it internally)
    final sl = GetIt.instance;
    if (!sl.isRegistered<IFCMService>()) {
      sl.registerLazySingleton<IFCMService>(() => _MockFCMService());
    }

    mockAuth = _MockAuthService();
    mockSettings = _MockUserSettingsService();
    provider = AuthProvider(
      authService: mockAuth,
      userSettingsService: mockSettings,
    );
  });

  tearDown(() {
    provider.dispose();
    mockAuth.dispose();
    GetIt.instance.reset();
  });

  group('AuthProvider', () {
    group('clearMessages', () {
      test('clears error message', () {
        // Trigger an error by signing in with empty fields
        provider.signIn('', 'password');

        expect(provider.errorMessage, isNotEmpty);

        provider.clearMessages();

        expect(provider.errorMessage, isEmpty);
        expect(provider.successMessage, isEmpty);
      });

      test('clears success message', () async {
        mockAuth.seedUser(
            email: 'test@example.com',
            password: 'pass123',
            emailVerified: true);

        // sendPasswordReset sets a success message
        await provider.sendPasswordReset('test@example.com');
        expect(provider.successMessage, isNotEmpty);

        provider.clearMessages();

        expect(provider.successMessage, isEmpty);
        expect(provider.errorMessage, isEmpty);
      });
    });

    group('signIn', () {
      test('does not set success message on successful sign-in', () async {
        mockAuth.seedUser(
            email: 'user@example.com',
            password: 'pass123',
            emailVerified: true);

        final result =
            await provider.signIn('user@example.com', 'pass123');

        expect(result, isTrue);
        expect(provider.successMessage, isEmpty);
        expect(provider.errorMessage, isEmpty);
      });

      test('sets error message on failed sign-in', () async {
        mockAuth.seedUser(
            email: 'user@example.com', password: 'correct');

        final result =
            await provider.signIn('user@example.com', 'wrong');

        expect(result, isFalse);
        expect(provider.errorMessage, 'Invalid email or password');
        expect(provider.successMessage, isEmpty);
      });

      test('sets error for empty email', () async {
        final result = await provider.signIn('', 'password');

        expect(result, isFalse);
        expect(provider.errorMessage,
            'Please enter both email and password');
      });
    });

    group('register', () {
      test(
          'does not set success message on successful registration',
          () async {
        final result = await provider.register(
          email: 'new@example.com',
          password: 'pass123',
          firstName: 'Jane',
          lastName: 'Doe',
        );

        expect(result, isTrue);
        expect(provider.successMessage, isEmpty);
        expect(provider.isAwaitingEmailVerification, isTrue);
      });

      test('sets error message on failed registration', () async {
        // Seed an existing account so registration fails
        mockAuth.seedUser(
            email: 'taken@example.com', password: 'pass');

        final result = await provider.register(
          email: 'taken@example.com',
          password: 'pass123',
          firstName: 'Jane',
          lastName: 'Doe',
        );

        expect(result, isFalse);
        expect(provider.errorMessage, 'Email already in use');
        expect(provider.successMessage, isEmpty);
      });

      test('sets error for empty fields', () async {
        final result = await provider.register(
          email: '',
          password: 'pass123',
          firstName: 'Jane',
          lastName: 'Doe',
        );

        expect(result, isFalse);
        expect(provider.errorMessage,
            'Please fill in all required fields');
      });
    });

    group('sendPasswordReset', () {
      test('sets success message on success', () async {
        final result =
            await provider.sendPasswordReset('user@example.com');

        expect(result, isTrue);
        expect(provider.successMessage, 'Password reset email sent');
        expect(provider.errorMessage, isEmpty);
      });
    });
  });
}
