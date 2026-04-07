import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart' show MockUser;
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_up_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_out_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/reset_password_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/enable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/disable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_with_biometrics_usecase.dart';
import 'package:rivr/models/2_usecases/features/settings/sync_settings_after_login_usecase.dart';
import 'package:rivr/services/1_contracts/features/settings/i_settings_repository.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';

// ---------------------------------------------------------------------------
// Minimal mocks for AuthProvider unit tests
// ---------------------------------------------------------------------------

class _MockAuthRepository implements IAuthRepository {
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

  /// Simulate sign-in (used by the mock use case wrapper)
  void simulateSignIn(String email) {
    final account = _accounts[email];
    if (account == null) return;
    _signedInUser = MockUser(
      uid: 'uid-${email.hashCode}',
      email: email,
      displayName: 'Test User',
      isEmailVerified: _emailVerified,
    );
    _authStateController.add(_signedInUser);
  }

  @override
  fb.User? get currentUser => _signedInUser;

  @override
  Stream<fb.User?> get authStateChanges => _authStateController.stream;

  @override
  Future<ServiceResult<fb.User?>> signIn({
    required String email,
    required String password,
  }) async {
    final account = _accounts[email];
    if (account == null || account['password'] != password) {
      return ServiceResult.failure(
        const ServiceException.auth('Invalid email or password'),
      );
    }
    simulateSignIn(email);
    return ServiceResult.success(_signedInUser);
  }

  @override
  Future<ServiceResult<fb.User?>> signUp({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    if (_accounts.containsKey(email)) {
      return ServiceResult.failure(
        const ServiceException.auth('Email already in use'),
      );
    }
    _accounts[email] = {'password': password};
    _signedInUser = MockUser(
      uid: 'uid-${email.hashCode}',
      email: email,
      displayName: '$firstName $lastName',
      isEmailVerified: false,
    );
    _authStateController.add(_signedInUser);
    return ServiceResult.success(_signedInUser);
  }

  @override
  Future<ServiceResult<void>> signOut() async {
    _signedInUser = null;
    _authStateController.add(null);
    return ServiceResult.success(null);
  }

  @override
  Future<ServiceResult<void>> resetPassword({required String email}) async =>
      ServiceResult.success(null);

  @override
  Future<bool> isBiometricAvailable() async => false;
  @override
  Future<bool> isBiometricEnabled() async => false;

  @override
  Future<ServiceResult<fb.User?>> signInWithBiometrics() async =>
      ServiceResult.failure(const ServiceException.auth('N/A'));

  @override
  Future<ServiceResult<void>> enableBiometric() async =>
      ServiceResult.failure(const ServiceException.auth('N/A'));

  @override
  Future<ServiceResult<void>> disableBiometric() async =>
      ServiceResult.failure(const ServiceException.auth('N/A'));

  @override
  Future<ServiceResult<UserSettings?>> syncSettingsAfterLogin(
      String userId) async =>
      ServiceResult.success(null);

  @override
  Future<ServiceResult<void>> sendEmailVerification() async =>
      ServiceResult.success(null);

  @override
  Future<ServiceResult<bool>> checkEmailVerified() async =>
      ServiceResult.success(_emailVerified);

  void dispose() => _authStateController.close();
}

class _MockSettingsRepository implements ISettingsRepository {
  @override
  Future<ServiceResult<UserSettings?>> getUserSettings(String userId) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<UserSettings?>> updateFlowUnit(
          String userId, FlowUnit flowUnit) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<UserSettings?>> updateNotifications(
          String userId, bool enableNotifications) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<UserSettings?>> updateNotificationFrequency(
          String userId, int frequency) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<UserSettings?>> syncAfterLogin(String userId) async =>
      ServiceResult.success(null);
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
  late _MockAuthRepository mockAuthRepo;
  late _MockSettingsRepository mockSettingsRepo;
  late _MockFCMService mockFcm;
  late AuthProvider provider;

  setUp(() {
    mockAuthRepo = _MockAuthRepository();
    mockSettingsRepo = _MockSettingsRepository();
    mockFcm = _MockFCMService();
    provider = AuthProvider(
      authRepository: mockAuthRepo,
      signInUseCase: SignInUseCase(mockAuthRepo),
      signUpUseCase: SignUpUseCase(mockAuthRepo),
      signOutUseCase: SignOutUseCase(mockAuthRepo),
      resetPasswordUseCase: ResetPasswordUseCase(mockAuthRepo),
      enableBiometricUseCase: EnableBiometricUseCase(mockAuthRepo),
      disableBiometricUseCase: DisableBiometricUseCase(mockAuthRepo),
      signInWithBiometricsUseCase: SignInWithBiometricsUseCase(mockAuthRepo),
      syncSettingsUseCase: SyncSettingsAfterLoginUseCase(mockSettingsRepo),
      fcmService: mockFcm,
    );
  });

  tearDown(() {
    provider.dispose();
    mockAuthRepo.dispose();
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
        mockAuthRepo.seedUser(
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
        mockAuthRepo.seedUser(
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
        mockAuthRepo.seedUser(
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
        mockAuthRepo.seedUser(
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
