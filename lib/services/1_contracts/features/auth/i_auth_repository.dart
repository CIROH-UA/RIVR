// lib/services/1_contracts/features/auth/i_auth_repository.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

/// Repository contract for authentication operations.
///
/// All fallible methods return [ServiceResult] so use cases and UI can handle
/// success/failure without catching exceptions. Stream and synchronous getters
/// remain unwrapped.
abstract class IAuthRepository {
  User? get currentUser;
  Stream<User?> get authStateChanges;

  Future<ServiceResult<User?>> signIn({required String email, required String password});
  Future<ServiceResult<User?>> signUp({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  });
  Future<ServiceResult<void>> signOut();
  Future<ServiceResult<void>> resetPassword({required String email});

  /// ADR 0014 — guest identity. Returns the existing user when one is signed
  /// in; otherwise mints an anonymous one and its `users/{uid}` document.
  Future<ServiceResult<User?>> signInAnonymously();

  /// ADR 0014 — sign of life for guest garbage collection. Never fails.
  Future<void> touchLastActive(String userId);

  /// ADR 0014 UX-3 — remember that the account prompt was shown. Never fails.
  Future<void> markAccountPromptShown(String userId);

  Future<bool> isBiometricAvailable();
  Future<bool> isBiometricEnabled();
  Future<ServiceResult<User?>> signInWithBiometrics();
  Future<ServiceResult<void>> enableBiometric();
  Future<ServiceResult<void>> disableBiometric();

  /// Sync user settings after a successful login.
  Future<ServiceResult<UserSettings?>> syncSettingsAfterLogin(String userId);

  Future<ServiceResult<void>> sendEmailVerification();
  Future<ServiceResult<bool>> checkEmailVerified();

  /// Permanently delete the currently signed-in account.
  ///
  /// Required by App Store Review Guideline 5.1.1(v). Reauthenticates with
  /// [password], removes FCM token registration, deletes the user's Firestore
  /// settings document, then deletes the Firebase Auth user (which also
  /// clears any local biometric credentials).
  ///
  /// A guest (ADR 0014) has no password: pass null and the reauthentication
  /// step is skipped — Firebase does not require it for an anonymous user.
  Future<ServiceResult<void>> deleteAccount({required String? password});
}
