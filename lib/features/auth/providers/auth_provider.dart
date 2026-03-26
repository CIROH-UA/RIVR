// lib/features/auth/providers/auth_provider.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/features/auth/models/auth_user.dart';
import '../../../core/services/i_auth_service.dart';
import '../../../core/services/i_fcm_service.dart';
import '../../../core/models/user_settings.dart';
import 'package:rivr/core/services/i_user_settings_service.dart';
import '../../../core/services/app_logger.dart';

/// Simple authentication state management for RIVR
class AuthProvider with ChangeNotifier {
  final IAuthService _authService;
  final IUserSettingsService _userSettingsService;

  AuthProvider({
    IAuthService? authService,
    IUserSettingsService? userSettingsService,
  })  : _authService = authService ?? GetIt.I<IAuthService>(),
        _userSettingsService =
            userSettingsService ?? GetIt.I<IUserSettingsService>();

  // State
  AuthUser? _currentUser;
  UserSettings? _currentUserSettings;
  bool _isLoading = false;
  String _errorMessage = '';
  String _successMessage = '';
  bool _isInitialized = false;
  bool _isAwaitingEmailVerification = false;

  // Getters
  AuthUser? get currentUser => _currentUser;
  UserSettings? get currentUserSettings => _currentUserSettings;
  bool get isAuthenticated =>
      _currentUser != null && !_isAwaitingEmailVerification;
  bool get isAwaitingEmailVerification => _isAwaitingEmailVerification;
  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;
  String get successMessage => _successMessage;
  bool get isInitialized => _isInitialized;

  // Auth state subscription
  StreamSubscription<dynamic>? _authStateSubscription;

  // Biometric capabilities (cached)
  bool? _biometricAvailable;
  bool? _biometricEnabled;

  /// Initialize the provider
  Future<void> initialize() async {
    AppLogger.info('AuthProvider', 'Initializing...');

    // Listen to auth state changes
    _authStateSubscription = _authService.authStateChanges.listen((firebaseUser) async {
      if (firebaseUser != null) {
        _currentUser = AuthUser.fromFirebaseUser(firebaseUser);
        AppLogger.info('AuthProvider', 'User signed in: ${_currentUser!.uid}');

        // Gate on email verification
        if (!firebaseUser.emailVerified) {
          _isAwaitingEmailVerification = true;
          AppLogger.info('AuthProvider', 'Email not verified, awaiting verification');
        }

        // Fetch user settings
        await _loadUserSettings();
      } else {
        _currentUser = null;
        _currentUserSettings = null;
        _isAwaitingEmailVerification = false;
        AppLogger.info('AuthProvider', 'User signed out');
      }
      notifyListeners();
    });

    // Set current user if already signed in
    final firebaseUser = _authService.currentUser;
    if (firebaseUser != null) {
      _currentUser = AuthUser.fromFirebaseUser(firebaseUser);
      if (!firebaseUser.emailVerified) {
        _isAwaitingEmailVerification = true;
      }
      await _loadUserSettings();
    }

    _isInitialized = true;
    notifyListeners();
    AppLogger.info('AuthProvider', 'Initialization complete');
  }

  /// Load user settings from Firestore
  Future<void> _loadUserSettings() async {
    if (_currentUser == null) return;

    try {
      AppLogger.debug('AuthProvider', 'Loading user settings for: ${_currentUser!.uid}');
      _currentUserSettings = await _userSettingsService.getUserSettings(
        _currentUser!.uid,
      );
      AppLogger.info('AuthProvider', 'User settings loaded successfully');

      // Set up notification listeners and refresh token if notifications are enabled
      if (_currentUserSettings?.enableNotifications == true) {
        AppLogger.debug('AuthProvider', 'Notifications enabled, setting up listeners');
        final fcmService = GetIt.I<IFCMService>();
        fcmService.setupNotificationListeners();
        await fcmService.refreshTokenIfNeeded(_currentUser!.uid);
      }
    } catch (e) {
      AppLogger.error('AuthProvider', 'Error loading user settings: $e', e);
      // Don't throw - user can still use the app without settings
      _currentUserSettings = null;
    }
  }

  /// Refresh user settings (call this after updating settings elsewhere)
  Future<void> refreshUserSettings() async {
    await _loadUserSettings();
    notifyListeners();
  }

  // MARK: - Authentication Methods

  /// Sign in with email and password
  Future<bool> signIn(String email, String password) async {
    if (email.trim().isEmpty || password.isEmpty) {
      _setError('Please enter both email and password');
      return false;
    }

    _setLoading(true);
    _clearMessages();

    final result = await _authService.signInWithEmailAndPassword(
      email: email,
      password: password,
    );

    _setLoading(false);

    if (result.isSuccess) {
      return true;
    } else {
      _setError(result.error ?? 'Sign in failed');
      return false;
    }
  }

  /// Register with email and password
  Future<bool> register({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    if (email.trim().isEmpty ||
        password.isEmpty ||
        firstName.trim().isEmpty ||
        lastName.trim().isEmpty) {
      _setError('Please fill in all required fields');
      return false;
    }

    _setLoading(true);
    _clearMessages();

    final result = await _authService.registerWithEmailAndPassword(
      email: email,
      password: password,
      firstName: firstName,
      lastName: lastName,
    );

    _setLoading(false);

    if (result.isSuccess) {
      _isAwaitingEmailVerification = true;
      notifyListeners();
      return true;
    } else {
      _setError(result.error ?? 'Registration failed');
      return false;
    }
  }

  /// Send password reset email
  Future<bool> sendPasswordReset(String email) async {
    if (email.trim().isEmpty) {
      _setError('Please enter your email address');
      return false;
    }

    _setLoading(true);
    _clearMessages();

    final result = await _authService.sendPasswordResetEmail(email: email);

    _setLoading(false);

    if (result.isSuccess) {
      _setSuccess('Password reset email sent');
      return true;
    } else {
      _setError(result.error ?? 'Failed to send reset email');
      return false;
    }
  }

  /// Sign out current user
  Future<void> signOut() async {
    _setLoading(true);

    final result = await _authService.signOut();

    _setLoading(false);

    if (result.isSuccess) {
      // Clear biometric cache, user settings, and FCM token cache
      _biometricAvailable = null;
      _biometricEnabled = null;
      _currentUserSettings = null;
      GetIt.I<IFCMService>().clearCache();
      _setSuccess('Signed out successfully');
    } else {
      _setError(result.error ?? 'Sign out failed');
    }
  }

  // MARK: - Email Verification

  /// Send verification email to current user
  Future<bool> sendVerificationEmail() async {
    _setLoading(true);
    _clearMessages();

    final result = await _authService.sendEmailVerification();

    _setLoading(false);

    if (result.isSuccess) {
      _setSuccess('Verification email sent. Check your inbox.');
      return true;
    } else {
      _setError(result.error ?? 'Failed to send verification email');
      return false;
    }
  }

  /// Check if current user's email has been verified (retries up to 3 times)
  Future<bool> checkEmailVerified() async {
    _setLoading(true);
    _clearMessages();

    // Retry up to 3 times with increasing delay to handle propagation lag
    for (int attempt = 1; attempt <= 3; attempt++) {
      final verified = await _authService.checkEmailVerified();

      if (verified) {
        _setLoading(false);
        _isAwaitingEmailVerification = false;
        _setSuccess('Email verified successfully!');
        notifyListeners();
        return true;
      }

      if (attempt < 3) {
        // Brief delay before retry to allow Firebase to propagate
        await Future.delayed(Duration(seconds: attempt));
      }
    }

    _setLoading(false);
    _setError('Email not yet verified. Check your inbox and try again.');
    return false;
  }

  /// Get the current user's email address (for display on verification page)
  String get currentUserEmail => _currentUser?.email ?? '';

  // MARK: - Biometric Authentication

  /// Check if biometric authentication is available
  Future<bool> get isBiometricAvailable async {
    _biometricAvailable ??= await _authService.isBiometricAvailable();
    return _biometricAvailable!;
  }

  /// Check if biometric login is enabled
  Future<bool> get isBiometricEnabled async {
    _biometricEnabled ??= await _authService.isBiometricEnabled();
    return _biometricEnabled!;
  }

  /// Enable biometric login
  Future<bool> enableBiometric() async {
    if (!isAuthenticated) {
      _setError('Please sign in first');
      return false;
    }

    _setLoading(true);
    _clearMessages();

    final result = await _authService.enableBiometricLogin();

    _setLoading(false);

    if (result.isSuccess) {
      _biometricEnabled = true; // Update cache
      _setSuccess('Biometric login enabled');
      return true;
    } else {
      _setError(result.error ?? 'Failed to enable biometric login');
      return false;
    }
  }

  /// Disable biometric login
  Future<bool> disableBiometric() async {
    _setLoading(true);
    _clearMessages();

    final result = await _authService.disableBiometricLogin();

    _setLoading(false);

    if (result.isSuccess) {
      _biometricEnabled = false; // Update cache
      _setSuccess('Biometric login disabled');
      return true;
    } else {
      _setError(result.error ?? 'Failed to disable biometric login');
      return false;
    }
  }

  /// Sign in with biometrics
  Future<bool> signInWithBiometric() async {
    _setLoading(true);
    _clearMessages();

    final result = await _authService.signInWithBiometrics();

    _setLoading(false);

    if (result.isSuccess) {
      _setSuccess('Biometric sign in successful');
      return true;
    } else {
      _setError(result.error ?? 'Biometric sign in failed');
      return false;
    }
  }

  // MARK: - User Information Getters

  /// Get user's display name (fallback to email if no name available)
  String get userDisplayName {
    if (_currentUserSettings != null) {
      final fullName = _currentUserSettings!.fullName;
      if (fullName.isNotEmpty) return fullName;
    }

    if (_currentUser?.displayName?.isNotEmpty == true) {
      return _currentUser!.displayName!;
    }

    return _currentUser?.email ?? 'User';
  }

  /// Get user's first name from UserSettings
  String get userFirstName {
    return _currentUserSettings?.firstName ?? _currentUser?.firstName ?? '';
  }

  /// Get user's last name from UserSettings
  String get userLastName {
    return _currentUserSettings?.lastName ?? _currentUser?.lastName ?? '';
  }

  /// Get formatted user name for display (e.g., "Santiago T.")
  String get userDisplayNameShort {
    final firstName = userFirstName;
    final lastName = userLastName;

    if (firstName.isEmpty) {
      return _currentUser?.email.split('@').first ?? 'User';
    }

    if (lastName.isEmpty) {
      return firstName;
    }

    // Return "FirstName L." format
    return '$firstName ${lastName.substring(0, 1).toUpperCase()}.';
  }

  /// Get user's full name from UserSettings
  String get userFullName {
    return _currentUserSettings?.fullName ?? userDisplayName;
  }

  // MARK: - Helper Methods

  void _setLoading(bool loading) {
    if (_isLoading != loading) {
      _isLoading = loading;
      notifyListeners();
    }
  }

  void _setError(String error) {
    if (_errorMessage != error || _successMessage != '') {
      _errorMessage = error;
      _successMessage = '';
      notifyListeners();
    }
    AppLogger.error('AuthProvider', 'Error - $error');
  }

  void _setSuccess(String message) {
    if (_successMessage != message || _errorMessage != '') {
      _successMessage = message;
      _errorMessage = '';
      notifyListeners();
    }
    AppLogger.info('AuthProvider', 'Success - $message');
  }

  void _clearMessages() {
    if (_errorMessage != '' || _successMessage != '') {
      _errorMessage = '';
      _successMessage = '';
      notifyListeners();
    }
  }

  /// Clear all messages (called from UI)
  void clearMessages() {
    _clearMessages();
  }

  /// Check if the current error suggests user should retry
  bool get shouldRetry {
    return _errorMessage.contains('network') ||
        _errorMessage.contains('connection') ||
        _errorMessage.contains('timeout');
  }

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    super.dispose();
  }
}
