// lib/features/auth/data/repositories/auth_repository_impl.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/services/i_auth_service.dart';
import 'package:rivr/core/services/auth_service.dart';
import 'package:rivr/core/services/i_user_settings_service.dart';
import 'package:rivr/core/services/service_result.dart';
import '../../domain/repositories/i_auth_repository.dart';

/// Coordinator that wraps [IAuthService] and [IUserSettingsService] operations
/// with [ServiceResult] error handling.
///
/// Converts [AuthResult] responses into [ServiceResult] so that use cases
/// return structured results instead of legacy wrappers.
class AuthRepositoryImpl implements IAuthRepository {
  final IAuthService _authService;
  final IUserSettingsService _settingsService;

  const AuthRepositoryImpl({
    required IAuthService authService,
    required IUserSettingsService settingsService,
  })  : _authService = authService,
        _settingsService = settingsService;

  @override
  User? get currentUser => _authService.currentUser;

  @override
  Stream<User?> get authStateChanges => _authService.authStateChanges;

  @override
  Future<ServiceResult<User?>> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final result = await _authService.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return _mapAuthResult(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'signIn'),
      );
    }
  }

  @override
  Future<ServiceResult<User?>> signUp({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    try {
      final result = await _authService.registerWithEmailAndPassword(
        email: email,
        password: password,
        firstName: firstName,
        lastName: lastName,
      );
      return _mapAuthResult(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'signUp'),
      );
    }
  }

  @override
  Future<ServiceResult<void>> signOut() async {
    try {
      final result = await _authService.signOut();
      return _mapAuthResultVoid(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'signOut'),
      );
    }
  }

  @override
  Future<ServiceResult<void>> resetPassword({required String email}) async {
    try {
      final result = await _authService.sendPasswordResetEmail(email: email);
      return _mapAuthResultVoid(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'resetPassword'),
      );
    }
  }

  @override
  Future<bool> isBiometricAvailable() => _authService.isBiometricAvailable();

  @override
  Future<bool> isBiometricEnabled() => _authService.isBiometricEnabled();

  @override
  Future<ServiceResult<User?>> signInWithBiometrics() async {
    try {
      final result = await _authService.signInWithBiometrics();
      return _mapAuthResult(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'signInWithBiometrics'),
      );
    }
  }

  @override
  Future<ServiceResult<void>> enableBiometric() async {
    try {
      final result = await _authService.enableBiometricLogin();
      return _mapAuthResultVoid(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'enableBiometric'),
      );
    }
  }

  @override
  Future<ServiceResult<void>> disableBiometric() async {
    try {
      final result = await _authService.disableBiometricLogin();
      return _mapAuthResultVoid(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'disableBiometric'),
      );
    }
  }

  @override
  Future<ServiceResult<UserSettings?>> syncSettingsAfterLogin(
    String userId,
  ) async {
    try {
      final settings = await _settingsService.syncAfterLogin(userId);
      return ServiceResult.success(settings);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'syncSettingsAfterLogin'),
      );
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Map [AuthResult] to [ServiceResult<User?>] for operations that return a user.
  ServiceResult<User?> _mapAuthResult(AuthResult result) {
    if (result.isSuccess) {
      return ServiceResult.success(result.user);
    }
    return ServiceResult.failure(
      ServiceException.auth(result.error ?? 'Authentication failed'),
    );
  }

  /// Map [AuthResult] to [ServiceResult<void>] for operations without data.
  ServiceResult<void> _mapAuthResultVoid(AuthResult result) {
    if (result.isSuccess) {
      return ServiceResult.success(null);
    }
    return ServiceResult.failure(
      ServiceException.auth(result.error ?? 'Operation failed'),
    );
  }
}
