// test/services/2_coordinators/features/auth/auth_repository_impl_test.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/4_infrastructure/auth/auth_service.dart';
import 'package:rivr/services/1_contracts/shared/i_auth_service.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/2_coordinators/features/auth/auth_repository_impl.dart';

// ── Stubs ───────────────────────────────────────────────────────────────────

class _StubAuthService implements IAuthService {
  AuthResult? signInResult;
  AuthResult? signUpResult;
  AuthResult? signOutResult;
  AuthResult? resetPasswordResult;
  AuthResult? biometricSignInResult;
  AuthResult? enableBiometricResult;
  AuthResult? disableBiometricResult;
  AuthResult? sendEmailVerificationResult;
  bool biometricAvailable = false;
  bool biometricEnabled = false;
  bool emailVerified = true;
  Exception? exceptionToThrow;

  final MockUser _mockUser = MockUser(
    uid: 'user1',
    email: 'test@example.com',
    displayName: 'Test User',
  );

  @override
  User? get currentUser => _mockUser;

  @override
  Stream<User?> get authStateChanges => Stream.value(_mockUser);

  @override
  bool get isSignedIn => true;

  @override
  Future<AuthResult> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return signInResult ?? AuthResult.success(_mockUser);
  }

  @override
  Future<AuthResult> registerWithEmailAndPassword({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return signUpResult ?? AuthResult.success(_mockUser);
  }

  @override
  Future<AuthResult> signOut() async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return signOutResult ?? AuthResult.success(null, message: 'Signed out');
  }

  @override
  Future<AuthResult> sendPasswordResetEmail({required String email}) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return resetPasswordResult ??
        AuthResult.success(null, message: 'Reset email sent');
  }

  @override
  Future<bool> isBiometricAvailable() async => biometricAvailable;

  @override
  Future<bool> isBiometricEnabled() async => biometricEnabled;

  @override
  Future<AuthResult> signInWithBiometrics() async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return biometricSignInResult ?? AuthResult.success(_mockUser);
  }

  @override
  Future<AuthResult> enableBiometricLogin() async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return enableBiometricResult ??
        AuthResult.success(null, message: 'Biometric enabled');
  }

  @override
  Future<AuthResult> disableBiometricLogin() async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return disableBiometricResult ??
        AuthResult.success(null, message: 'Biometric disabled');
  }

  @override
  Future<AuthResult> updateDisplayName(String displayName) async =>
      AuthResult.success(_mockUser);

  @override
  Future<void> reloadUser() async {}

  @override
  Future<AuthResult> sendEmailVerification() async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return sendEmailVerificationResult ??
        AuthResult.success(null, message: 'Sent');
  }

  @override
  Future<bool> checkEmailVerified() async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return emailVerified;
  }
}

class _StubSettingsService implements IUserSettingsService {
  UserSettings? settingsToReturn;
  Exception? exceptionToThrow;

  @override
  Future<UserSettings?> syncAfterLogin(String userId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return settingsToReturn;
  }

  // ── Unused interface methods ────────────────────────────────────────────
  @override
  Future<UserSettings?> getUserSettings(String userId) async => null;
  @override
  Future<void> saveUserSettings(UserSettings settings) async {}
  @override
  Future<void> updateUserSettings(
    String userId,
    Map<String, dynamic> updates,
  ) async {}
  @override
  Future<UserSettings?> addCustomBackgroundImage(
    String userId,
    String imagePath,
  ) async =>
      null;
  @override
  Future<UserSettings?> removeCustomBackgroundImage(
    String userId,
    String imagePath,
  ) async =>
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
      throw UnimplementedError();
  @override
  Future<UserSettings?> addFavoriteReach(String userId, String reachId) async =>
      null;
  @override
  Future<UserSettings?> removeFavoriteReach(
    String userId,
    String reachId,
  ) async =>
      null;
  @override
  Future<UserSettings?> updateFlowUnit(String userId, FlowUnit flowUnit) async =>
      null;
  @override
  Future<UserSettings?> updateNotifications(
    String userId,
    bool enableNotifications,
  ) async =>
      null;
  @override
  Future<UserSettings?> updateNotificationFrequency(
    String userId,
    int frequency,
  ) async =>
      null;
  @override
  void clearCache() {}
  @override
  Future<bool> userHasSettings(String userId) async => false;
  @override
  Future<void> syncFlowUnitPreference(String userId) async {}
}

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  late _StubAuthService stubAuth;
  late _StubSettingsService stubSettings;
  late AuthRepositoryImpl repository;

  setUp(() {
    stubAuth = _StubAuthService();
    stubSettings = _StubSettingsService();
    repository = AuthRepositoryImpl(
      authService: stubAuth,
      settingsService: stubSettings,
    );
  });

  group('AuthRepositoryImpl — signIn', () {
    test('returns success with user on successful sign in', () async {
      final result = await repository.signIn(
        email: 'test@example.com',
        password: 'password123',
      );
      expect(result.isSuccess, isTrue);
      expect(result.data, isNotNull);
      expect(result.data!.email, 'test@example.com');
    });

    test('returns failure when auth service returns failure', () async {
      stubAuth.signInResult = AuthResult.failure('Invalid credentials');

      final result = await repository.signIn(
        email: 'test@example.com',
        password: 'wrong',
      );
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, 'Invalid credentials');
    });

    test('returns failure when service throws', () async {
      stubAuth.exceptionToThrow = Exception('Network error');

      final result = await repository.signIn(
        email: 'test@example.com',
        password: 'password123',
      );
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('AuthRepositoryImpl — signUp', () {
    test('returns success with user on successful registration', () async {
      final result = await repository.signUp(
        email: 'new@example.com',
        password: 'password123',
        firstName: 'New',
        lastName: 'User',
      );
      expect(result.isSuccess, isTrue);
      expect(result.data, isNotNull);
    });

    test('returns failure when auth service returns failure', () async {
      stubAuth.signUpResult = AuthResult.failure('Email already in use');

      final result = await repository.signUp(
        email: 'existing@example.com',
        password: 'password123',
        firstName: 'Test',
        lastName: 'User',
      );
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, 'Email already in use');
    });
  });

  group('AuthRepositoryImpl — signOut', () {
    test('returns success on successful sign out', () async {
      final result = await repository.signOut();
      expect(result.isSuccess, isTrue);
    });

    test('returns failure when service throws', () async {
      stubAuth.exceptionToThrow = Exception('Sign out failed');

      final result = await repository.signOut();
      expect(result.isFailure, isTrue);
    });
  });

  group('AuthRepositoryImpl — resetPassword', () {
    test('returns success on successful password reset', () async {
      final result = await repository.resetPassword(email: 'test@example.com');
      expect(result.isSuccess, isTrue);
    });

    test('returns failure when auth service returns failure', () async {
      stubAuth.resetPasswordResult = AuthResult.failure('User not found');

      final result = await repository.resetPassword(email: 'unknown@example.com');
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, 'User not found');
    });
  });

  group('AuthRepositoryImpl — biometric', () {
    test('signInWithBiometrics returns success with user', () async {
      final result = await repository.signInWithBiometrics();
      expect(result.isSuccess, isTrue);
      expect(result.data, isNotNull);
    });

    test('signInWithBiometrics returns failure on auth failure', () async {
      stubAuth.biometricSignInResult =
          AuthResult.failure('Biometric authentication failed');

      final result = await repository.signInWithBiometrics();
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, 'Biometric authentication failed');
    });

    test('enableBiometric returns success', () async {
      final result = await repository.enableBiometric();
      expect(result.isSuccess, isTrue);
    });

    test('disableBiometric returns success', () async {
      final result = await repository.disableBiometric();
      expect(result.isSuccess, isTrue);
    });

    test('isBiometricAvailable delegates to service', () async {
      stubAuth.biometricAvailable = true;
      expect(await repository.isBiometricAvailable(), isTrue);

      stubAuth.biometricAvailable = false;
      expect(await repository.isBiometricAvailable(), isFalse);
    });

    test('isBiometricEnabled delegates to service', () async {
      stubAuth.biometricEnabled = true;
      expect(await repository.isBiometricEnabled(), isTrue);

      stubAuth.biometricEnabled = false;
      expect(await repository.isBiometricEnabled(), isFalse);
    });
  });

  group('AuthRepositoryImpl — syncSettingsAfterLogin', () {
    test('returns success with settings', () async {
      final now = DateTime(2026, 4, 6);
      stubSettings.settingsToReturn = UserSettings(
        userId: 'user1',
        email: 'test@example.com',
        firstName: 'Test',
        lastName: 'User',
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twelveHour,
        enableNotifications: false,
        favoriteReachIds: [],
        lastLoginDate: now,
        createdAt: now,
        updatedAt: now,
      );

      final result = await repository.syncSettingsAfterLogin('user1');
      expect(result.isSuccess, isTrue);
      expect(result.data, isNotNull);
      expect(result.data!.userId, 'user1');
    });

    test('returns success with null when no settings', () async {
      stubSettings.settingsToReturn = null;

      final result = await repository.syncSettingsAfterLogin('user1');
      expect(result.isSuccess, isTrue);
      expect(result.data, isNull);
    });

    test('returns failure when settings service throws', () async {
      stubSettings.exceptionToThrow = Exception('Sync failed');

      final result = await repository.syncSettingsAfterLogin('user1');
      expect(result.isFailure, isTrue);
    });
  });

  group('AuthRepositoryImpl — sendEmailVerification', () {
    test('returns success on successful send', () async {
      final result = await repository.sendEmailVerification();
      expect(result.isSuccess, isTrue);
    });

    test('returns failure when auth service returns failure', () async {
      stubAuth.sendEmailVerificationResult =
          AuthResult.failure('Too many requests');

      final result = await repository.sendEmailVerification();
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, 'Too many requests');
    });

    test('returns failure when service throws', () async {
      stubAuth.exceptionToThrow = Exception('Network error');

      final result = await repository.sendEmailVerification();
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('AuthRepositoryImpl — checkEmailVerified', () {
    test('returns success with true when email is verified', () async {
      stubAuth.emailVerified = true;

      final result = await repository.checkEmailVerified();
      expect(result.isSuccess, isTrue);
      expect(result.data, isTrue);
    });

    test('returns success with false when email is not verified', () async {
      stubAuth.emailVerified = false;

      final result = await repository.checkEmailVerified();
      expect(result.isSuccess, isTrue);
      expect(result.data, isFalse);
    });

    test('returns failure when service throws', () async {
      stubAuth.exceptionToThrow = Exception('Network error');

      final result = await repository.checkEmailVerified();
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('AuthRepositoryImpl — properties', () {
    test('currentUser delegates to auth service', () {
      expect(repository.currentUser, isNotNull);
      expect(repository.currentUser!.email, 'test@example.com');
    });

    test('authStateChanges emits user', () async {
      final user = await repository.authStateChanges.first;
      expect(user, isNotNull);
      expect(user!.email, 'test@example.com');
    });
  });
}
