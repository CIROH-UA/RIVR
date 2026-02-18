// lib/core/services/auth_service.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/user_settings.dart';
import 'app_logger.dart';
import 'error_service.dart';

/// Simplified Firebase Auth wrapper service for RIVR
/// Handles all authentication operations with proper error handling
class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  // Firebase instances
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Biometric authentication
  final LocalAuthentication _localAuth = LocalAuthentication();

  // Secure storage for biometric credentials
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // Storage keys
  static const String _biometricEnabledKey = 'biometric_enabled';
  static const String _biometricUserIdKey = 'biometric_user_id';
  static const String _biometricEmailKey = 'biometric_email';

  /// Get current Firebase user
  User? get currentUser => _firebaseAuth.currentUser;

  /// Stream of authentication state changes
  Stream<User?> get authStateChanges => _firebaseAuth.authStateChanges();

  /// Check if user is currently signed in
  bool get isSignedIn => currentUser != null;

  // MARK: - Email/Password Authentication

  /// Sign in with email and password
  Future<AuthResult> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      AppLogger.debug('AuthService', 'Signing in with email: $email');

      final credential = await _firebaseAuth
          .signInWithEmailAndPassword(email: email.trim(), password: password)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw FirebaseAuthException(
              code: 'timeout',
              message: 'Sign in request timed out',
            ),
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
  Future<AuthResult> registerWithEmailAndPassword({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    try {
      AppLogger.debug('AuthService', 'Registering user with email: $email');

      final credential = await _firebaseAuth
          .createUserWithEmailAndPassword(
            email: email.trim(),
            password: password,
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw FirebaseAuthException(
              code: 'timeout',
              message: 'Registration request timed out',
            ),
          );

      if (credential.user == null) {
        return AuthResult.failure('Registration failed - no user returned');
      }

      final user = credential.user!;
      AppLogger.info('AuthService', 'Registration successful for user: ${user.uid}');

      // Update display name
      await user.updateDisplayName('$firstName $lastName');

      // Create UserSettings document in Firestore
      await _createUserSettings(
        userId: user.uid,
        email: email.trim(),
        firstName: firstName,
        lastName: lastName,
      );

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
        enableNotifications: true,
        enableDarkMode: false,
        favoriteReachIds: [],
        lastLoginDate: DateTime.now(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await _firestore
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
  Future<AuthResult> sendPasswordResetEmail({required String email}) async {
    try {
      AppLogger.debug('AuthService', 'Sending password reset email to: $email');

      await _firebaseAuth
          .sendPasswordResetEmail(email: email.trim())
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw FirebaseAuthException(
              code: 'timeout',
              message: 'Password reset request timed out',
            ),
          );

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
  Future<AuthResult> signOut() async {
    try {
      AppLogger.debug('AuthService', 'Signing out current user');

      await _firebaseAuth.signOut().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          AppLogger.warning('AuthService', 'Sign out timed out, but continuing');
          // Continue anyway - local session will be cleared
        },
      );

      // Clear biometric credentials on sign out
      await _clearBiometricCredentials();

      AppLogger.info('AuthService', 'Sign out successful');
      return AuthResult.success(null, message: 'Signed out successfully');
    } catch (e) {
      AppLogger.error('AuthService', 'Sign out error: $e', e);
      return AuthResult.failure('Sign out failed: ${e.toString()}');
    }
  }

  // MARK: - Biometric Authentication

  /// Check if device supports biometric authentication
  Future<bool> isBiometricAvailable() async {
    try {
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      return canCheckBiometrics && isDeviceSupported;
    } catch (e) {
      AppLogger.error('AuthService', 'Error checking biometric availability: $e', e);
      return false;
    }
  }

  /// Check if user has enabled biometric login
  Future<bool> isBiometricEnabled() async {
    try {
      final value = await _secureStorage.read(key: _biometricEnabledKey);
      return value == 'true';
    } catch (e) {
      AppLogger.error('AuthService', 'Error checking biometric enabled status: $e', e);
      return false;
    }
  }

  /// Enable biometric login for current user
  Future<AuthResult> enableBiometricLogin() async {
    try {
      if (currentUser == null) {
        return AuthResult.failure('No user signed in');
      }

      if (!await isBiometricAvailable()) {
        return AuthResult.failure('Biometric authentication not available');
      }

      // Authenticate with biometrics to confirm setup
      final authenticated = await _authenticateWithBiometrics(
        'Authenticate to enable biometric login',
      );

      if (!authenticated) {
        return AuthResult.failure('Biometric authentication failed');
      }

      // Store credentials securely
      await _secureStorage.write(key: _biometricEnabledKey, value: 'true');
      await _secureStorage.write(
        key: _biometricUserIdKey,
        value: currentUser!.uid,
      );
      await _secureStorage.write(
        key: _biometricEmailKey,
        value: currentUser!.email ?? '',
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
  Future<AuthResult> disableBiometricLogin() async {
    try {
      await _clearBiometricCredentials();
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
  Future<AuthResult> signInWithBiometrics() async {
    try {
      if (!await isBiometricAvailable()) {
        return AuthResult.failure('Biometric authentication not available');
      }

      if (!await isBiometricEnabled()) {
        return AuthResult.failure('Biometric login not enabled');
      }

      // Get stored credentials
      final userId = await _secureStorage.read(key: _biometricUserIdKey);
      final email = await _secureStorage.read(key: _biometricEmailKey);

      if (userId == null || email == null) {
        return AuthResult.failure('No biometric credentials found');
      }

      // Authenticate with biometrics
      final authenticated = await _authenticateWithBiometrics(
        'Use biometric authentication to sign in',
      );

      if (!authenticated) {
        return AuthResult.failure('Biometric authentication failed');
      }

      // Check if user still exists in Firebase
      if (currentUser?.uid != userId) {
        // User might be signed out or different user
        await _clearBiometricCredentials();
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

  /// Perform biometric authentication
  Future<bool> _authenticateWithBiometrics(String reason) async {
    try {
      return await _localAuth
          .authenticate(
            localizedReason: reason,
            options: const AuthenticationOptions(
              stickyAuth: true,
              biometricOnly: true,
            ),
          )
          .timeout(const Duration(seconds: 30), onTimeout: () => false);
    } catch (e) {
      AppLogger.error('AuthService', 'Biometric authentication error: $e', e);
      return false;
    }
  }

  /// Clear biometric credentials from secure storage
  Future<void> _clearBiometricCredentials() async {
    try {
      await _secureStorage.delete(key: _biometricEnabledKey);
      await _secureStorage.delete(key: _biometricUserIdKey);
      await _secureStorage.delete(key: _biometricEmailKey);
    } catch (e) {
      AppLogger.error('AuthService', 'Error clearing biometric credentials: $e', e);
    }
  }

  // MARK: - User Profile Management

  /// Update user display name
  Future<AuthResult> updateDisplayName(String displayName) async {
    try {
      if (currentUser == null) {
        return AuthResult.failure('No user signed in');
      }

      await currentUser!.updateDisplayName(displayName);
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
  Future<void> reloadUser() async {
    try {
      await currentUser?.reload();
    } catch (e) {
      AppLogger.error('AuthService', 'Error reloading user: $e', e);
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
