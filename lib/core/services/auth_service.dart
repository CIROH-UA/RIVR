// lib/core/services/auth_service.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_settings.dart';
import 'app_logger.dart';
import 'error_service.dart';
import 'i_auth_service.dart';
import 'service_result.dart';
import '../../features/auth/data/datasources/auth_firebase_datasource.dart';
import '../../features/auth/data/datasources/biometric_datasource.dart';

/// Firebase Auth wrapper service for RIVR.
///
/// Delegates raw Firebase Auth calls to [AuthFirebaseDatasource] and
/// biometric operations to [BiometricDatasource]. Implements [IAuthService]
/// for backward compatibility with consumers (e.g. [AuthProvider]) that
/// haven't migrated to use cases yet.
class AuthService implements IAuthService {
  final AuthFirebaseDatasource _authDatasource;
  final BiometricDatasource _biometricDatasource;

  AuthService({
    AuthFirebaseDatasource? authDatasource,
    BiometricDatasource? biometricDatasource,
  })  : _authDatasource = authDatasource ?? AuthFirebaseDatasource(),
        _biometricDatasource = biometricDatasource ?? BiometricDatasource();

  /// Get current Firebase user
  @override
  User? get currentUser => _authDatasource.currentUser;

  /// Stream of authentication state changes
  @override
  Stream<User?> get authStateChanges => _authDatasource.authStateChanges;

  /// Check if user is currently signed in
  @override
  bool get isSignedIn => _authDatasource.isSignedIn;

  // MARK: - Email/Password Authentication

  /// Sign in with email and password
  @override
  Future<AuthResult> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      AppLogger.debug('AuthService', 'Signing in with email: $email');

      final credential = await _authDatasource.signIn(
        email: email,
        password: password,
      );

      if (credential.user == null) {
        return AuthResult.failure('Sign in failed - no user returned');
      }

      AppLogger.info('AuthService', 'Sign in successful for user: ${credential.user!.uid}');
      return AuthResult.success(credential.user!);
    } on FirebaseAuthException catch (e) {
      AppLogger.error('AuthService', 'FirebaseAuthException: ${e.code} - ${e.message}', e);
      return AuthResult.failure(ErrorService.mapFirebaseAuthError(e));
    } catch (e) {
      AppLogger.error('AuthService', 'Unexpected sign in error: $e', e);
      return AuthResult.failure('Sign in failed: ${e.toString()}');
    }
  }

  /// Register with email and password
  @override
  Future<AuthResult> registerWithEmailAndPassword({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    try {
      AppLogger.debug('AuthService', 'Registering user with email: $email');

      final credential = await _authDatasource.register(
        email: email,
        password: password,
      );

      if (credential.user == null) {
        return AuthResult.failure('Registration failed - no user returned');
      }

      final user = credential.user!;
      AppLogger.info('AuthService', 'Registration successful for user: ${user.uid}');

      // Update display name
      await _authDatasource.updateDisplayName(user, '$firstName $lastName');

      // Create UserSettings document in Firestore
      await _createUserSettings(
        userId: user.uid,
        email: email.trim(),
        firstName: firstName,
        lastName: lastName,
      );

      // Send email verification (fire-and-forget)
      try {
        await _authDatasource.sendEmailVerification(user);
        AppLogger.info('AuthService', 'Verification email sent to ${email.trim()}');
      } catch (e) {
        AppLogger.warning('AuthService', 'Failed to send verification email: $e');
      }

      return AuthResult.success(user);
    } on FirebaseAuthException catch (e) {
      AppLogger.error('AuthService', 'Registration FirebaseAuthException: ${e.code} - ${e.message}', e);
      return AuthResult.failure(ErrorService.mapFirebaseAuthError(e));
    } catch (e) {
      AppLogger.error('AuthService', 'Unexpected registration error: $e', e);
      return AuthResult.failure('Registration failed: ${e.toString()}');
    }
  }

  /// Create UserSettings document after successful registration
  Future<void> _createUserSettings({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
  }) async {
    try {
      AppLogger.debug('AuthService', 'Creating UserSettings for user: $userId');

      final userSettings = UserSettings(
        userId: userId,
        email: email,
        firstName: firstName,
        lastName: lastName,
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twelveHour,
        enableNotifications: false,
        favoriteReachIds: [],
        lastLoginDate: DateTime.now(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set(userSettings.toJson())
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('UserSettings creation timed out'),
          );

      AppLogger.info('AuthService', 'UserSettings created successfully');
    } catch (e) {
      AppLogger.error('AuthService', 'Error creating UserSettings: $e', e);
      // Don't throw - registration was successful, this is just cleanup
    }
  }

  /// Send password reset email
  @override
  Future<AuthResult> sendPasswordResetEmail({required String email}) async {
    try {
      AppLogger.debug('AuthService', 'Sending password reset email to: $email');

      await _authDatasource.sendPasswordResetEmail(email);

      AppLogger.info('AuthService', 'Password reset email sent successfully');
      return AuthResult.success(null, message: 'Password reset email sent');
    } on FirebaseAuthException catch (e) {
      AppLogger.error('AuthService', 'Password reset FirebaseAuthException: ${e.code} - ${e.message}', e);
      return AuthResult.failure(ErrorService.mapFirebaseAuthError(e));
    } catch (e) {
      AppLogger.error('AuthService', 'Unexpected password reset error: $e', e);
      return AuthResult.failure(
        'Failed to send password reset email: ${e.toString()}',
      );
    }
  }

  /// Sign out current user
  @override
  Future<AuthResult> signOut() async {
    try {
      AppLogger.debug('AuthService', 'Signing out current user');

      await _authDatasource.signOut();

      // Clear biometric credentials on sign out
      await _biometricDatasource.clearCredentials();

      AppLogger.info('AuthService', 'Sign out successful');
      return AuthResult.success(null, message: 'Signed out successfully');
    } catch (e) {
      AppLogger.error('AuthService', 'Sign out error: $e', e);
      return AuthResult.failure('Sign out failed: ${e.toString()}');
    }
  }

  // MARK: - Biometric Authentication

  /// Check if device supports biometric authentication
  @override
  Future<bool> isBiometricAvailable() async {
    try {
      return await _biometricDatasource.isAvailable();
    } catch (e) {
      AppLogger.error('AuthService', 'Error checking biometric availability: $e', e);
      return false;
    }
  }

  /// Check if user has enabled biometric login
  @override
  Future<bool> isBiometricEnabled() async {
    try {
      return await _biometricDatasource.isEnabled();
    } catch (e) {
      AppLogger.error('AuthService', 'Error checking biometric enabled status: $e', e);
      return false;
    }
  }

  /// Enable biometric login for current user
  @override
  Future<AuthResult> enableBiometricLogin() async {
    try {
      if (currentUser == null) {
        return AuthResult.failure('No user signed in');
      }

      if (!await isBiometricAvailable()) {
        return AuthResult.failure('Biometric authentication not available');
      }

      // Authenticate with biometrics to confirm setup
      final authenticated = await _biometricDatasource.authenticate(
        'Authenticate to enable biometric login',
      );

      if (!authenticated) {
        return AuthResult.failure('Biometric authentication failed');
      }

      // Store credentials securely
      await _biometricDatasource.storeCredentials(
        userId: currentUser!.uid,
        email: currentUser!.email ?? '',
      );

      AppLogger.info('AuthService', 'Biometric login enabled successfully');
      return AuthResult.success(null, message: 'Biometric login enabled');
    } catch (e) {
      AppLogger.error('AuthService', 'Error enabling biometric login: $e', e);
      return AuthResult.failure(
        'Failed to enable biometric login: ${e.toString()}',
      );
    }
  }

  /// Disable biometric login
  @override
  Future<AuthResult> disableBiometricLogin() async {
    try {
      await _biometricDatasource.clearCredentials();
      AppLogger.info('AuthService', 'Biometric login disabled successfully');
      return AuthResult.success(null, message: 'Biometric login disabled');
    } catch (e) {
      AppLogger.error('AuthService', 'Error disabling biometric login: $e', e);
      return AuthResult.failure(
        'Failed to disable biometric login: ${e.toString()}',
      );
    }
  }

  /// Sign in using biometric authentication
  @override
  Future<AuthResult> signInWithBiometrics() async {
    try {
      if (!await isBiometricAvailable()) {
        return AuthResult.failure('Biometric authentication not available');
      }

      if (!await _biometricDatasource.isEnabled()) {
        return AuthResult.failure('Biometric login not enabled');
      }

      // Get stored credentials
      final userId = await _biometricDatasource.getStoredUserId();
      final email = await _biometricDatasource.getStoredEmail();

      if (userId == null || email == null) {
        return AuthResult.failure('No biometric credentials found');
      }

      // Authenticate with biometrics
      final authenticated = await _biometricDatasource.authenticate(
        'Use biometric authentication to sign in',
      );

      if (!authenticated) {
        return AuthResult.failure('Biometric authentication failed');
      }

      // Check if user still exists in Firebase
      if (currentUser?.uid != userId) {
        await _biometricDatasource.clearCredentials();
        return AuthResult.failure('Biometric credentials no longer valid');
      }

      AppLogger.info('AuthService', 'Biometric sign in successful for user: $userId');
      return AuthResult.success(
        currentUser!,
        message: 'Biometric sign in successful',
      );
    } catch (e) {
      AppLogger.error('AuthService', 'Biometric sign in error: $e', e);
      return AuthResult.failure('Biometric sign in failed: ${e.toString()}');
    }
  }

  // MARK: - User Profile Management

  /// Update user display name
  @override
  Future<AuthResult> updateDisplayName(String displayName) async {
    try {
      if (currentUser == null) {
        return AuthResult.failure('No user signed in');
      }

      await _authDatasource.updateDisplayName(currentUser!, displayName);
      AppLogger.info('AuthService', 'Display name updated successfully');
      return AuthResult.success(currentUser!, message: 'Display name updated');
    } catch (e) {
      AppLogger.error('AuthService', 'Error updating display name: $e', e);
      return AuthResult.failure(
        'Failed to update display name: ${e.toString()}',
      );
    }
  }

  /// Reload current user data
  @override
  Future<void> reloadUser() async {
    try {
      await _authDatasource.reloadUser();
    } catch (e) {
      AppLogger.error('AuthService', 'Error reloading user: $e', e);
    }
  }

  // MARK: - Email Verification

  /// Send email verification to current user
  @override
  Future<AuthResult> sendEmailVerification() async {
    try {
      if (currentUser == null) {
        return AuthResult.failure('No user signed in');
      }

      await _authDatasource.sendEmailVerification(currentUser!);

      AppLogger.info('AuthService', 'Verification email sent');
      return AuthResult.success(null, message: 'Verification email sent');
    } catch (e) {
      AppLogger.error('AuthService', 'Error sending verification email: $e', e);
      return AuthResult.failure('Failed to send verification email: ${e.toString()}');
    }
  }

  /// Check if current user's email is verified (reloads user first)
  @override
  Future<bool> checkEmailVerified() async {
    try {
      return await _authDatasource.checkEmailVerified();
    } catch (e) {
      AppLogger.error('AuthService', 'Error checking email verification: $e', e);
      return false;
    }
  }
}

/// Authentication result wrapper
class AuthResult {
  final bool isSuccess;
  final User? user;
  final String? message;
  final String? error;

  AuthResult.success(this.user, {this.message})
    : isSuccess = true,
      error = null;

  AuthResult.failure(this.error)
    : isSuccess = false,
      user = null,
      message = null;
}

/// Bridge from [AuthResult] to [ServiceResult] for incremental migration.
/// Auth use cases can wrap their return values during Phase 3 migration.
extension AuthResultToServiceResult on AuthResult {
  ServiceResult<User> toServiceResult() {
    if (isSuccess && user != null) {
      return ServiceResult.success(user!);
    }
    return ServiceResult.failure(
      ServiceException.auth(error ?? 'Authentication failed'),
    );
  }
}
