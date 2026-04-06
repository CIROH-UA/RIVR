// lib/features/auth/domain/repositories/i_auth_repository.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/services/service_result.dart';

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

  Future<bool> isBiometricAvailable();
  Future<bool> isBiometricEnabled();
  Future<ServiceResult<User?>> signInWithBiometrics();
  Future<ServiceResult<void>> enableBiometric();
  Future<ServiceResult<void>> disableBiometric();

  /// Sync user settings after a successful login.
  Future<ServiceResult<UserSettings?>> syncSettingsAfterLogin(String userId);
}
