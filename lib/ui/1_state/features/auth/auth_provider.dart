// lib/ui/1_state/features/auth/auth_provider.dart

import 'dart:async';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';
import 'package:rivr/models/1_domain/features/auth/auth_user.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_up_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_out_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/reset_password_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/enable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/disable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_with_biometrics_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/delete_account_usecase.dart';
import 'package:rivr/models/2_usecases/features/settings/sync_settings_after_login_usecase.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Simple authentication state management for RIVR
/// Whether this user can receive ANY notification, and therefore needs the
/// tap-routing listeners and a fresh FCM token.
///
/// Pure and top-level so the decision is testable without an auth session, a
/// use case or a Firebase mock — the reason the original defect had no test.
///
/// **ADR 0008 defect, carried into ADR 0011's Phase 9 list.** The gate was
/// `enableNotifications` alone. The Weekly Outlook shipped with its OWN
/// toggle, so a user can have flood alerts off and the weekly digest on — and
/// that user still gets a notification every Friday. With no listeners
/// registered, tapping it opened the app wherever it was last instead of
/// routing to the digest, and their token was never refreshed, so the weekly
/// could eventually stop arriving at all.
bool wantsAnyNotification(UserSettings? settings) =>
    settings?.enableNotifications == true ||
    settings?.weeklyOutlookEnabled == true;

class AuthProvider with ChangeNotifier {
  final IAuthRepository _authRepository;
  final SignInUseCase _signInUseCase;
  final SignUpUseCase _signUpUseCase;
  final SignOutUseCase _signOutUseCase;
  final ResetPasswordUseCase _resetPasswordUseCase;
  final EnableBiometricUseCase _enableBiometricUseCase;
  final DisableBiometricUseCase _disableBiometricUseCase;
  final SignInWithBiometricsUseCase _signInWithBiometricsUseCase;
  final SyncSettingsAfterLoginUseCase _syncSettingsUseCase;
  final DeleteAccountUseCase _deleteAccountUseCase;
  final IFCMService _fcmService;

  AuthProvider({
    IAuthRepository? authRepository,
    SignInUseCase? signInUseCase,
    SignUpUseCase? signUpUseCase,
    SignOutUseCase? signOutUseCase,
    ResetPasswordUseCase? resetPasswordUseCase,
    EnableBiometricUseCase? enableBiometricUseCase,
    DisableBiometricUseCase? disableBiometricUseCase,
    SignInWithBiometricsUseCase? signInWithBiometricsUseCase,
    SyncSettingsAfterLoginUseCase? syncSettingsUseCase,
    DeleteAccountUseCase? deleteAccountUseCase,
    IFCMService? fcmService,
  })  : _authRepository = authRepository ?? GetIt.I<IAuthRepository>(),
        _signInUseCase = signInUseCase ?? GetIt.I<SignInUseCase>(),
        _signUpUseCase = signUpUseCase ?? GetIt.I<SignUpUseCase>(),
        _signOutUseCase = signOutUseCase ?? GetIt.I<SignOutUseCase>(),
        _resetPasswordUseCase =
            resetPasswordUseCase ?? GetIt.I<ResetPasswordUseCase>(),
        _enableBiometricUseCase =
            enableBiometricUseCase ?? GetIt.I<EnableBiometricUseCase>(),
        _disableBiometricUseCase =
            disableBiometricUseCase ?? GetIt.I<DisableBiometricUseCase>(),
        _signInWithBiometricsUseCase = signInWithBiometricsUseCase ??
            GetIt.I<SignInWithBiometricsUseCase>(),
        _syncSettingsUseCase =
            syncSettingsUseCase ?? GetIt.I<SyncSettingsAfterLoginUseCase>(),
        _deleteAccountUseCase =
            deleteAccountUseCase ?? GetIt.I<DeleteAccountUseCase>(),
        _fcmService = fcmService ?? GetIt.I<IFCMService>();

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
    // Whether this session has SEEN a signed-in user. The stream can emit
    // null on a cold start (signed-out app open, or before the restored user
    // arrives); clearing on those would wipe a signed-out user's browse cache
    // pointlessly — or worse, a signed-IN user's pins file on every launch,
    // undoing the cold-start eviction fix outright. Only a null that FOLLOWS a
    // non-null is a sign-out.
    var hadUser = false;
    _authStateSubscription =
        _authRepository.authStateChanges.listen((firebaseUser) async {
      if (firebaseUser != null) {
        hadUser = true;
        _currentUser = AuthUser.fromFirebaseUser(firebaseUser);
        AppLogger.info(
            'AuthProvider', 'User signed in: ${_currentUser!.uid}');
        _setCrashlyticsUserSafe(firebaseUser.uid);

        // Gate on email verification
        if (!firebaseUser.emailVerified) {
          _isAwaitingEmailVerification = true;
          AppLogger.info(
              'AuthProvider', 'Email not verified, awaiting verification');
        }

        // Fetch user settings
        await _loadUserSettings();
      } else {
        _currentUser = null;
        _currentUserSettings = null;
        _isAwaitingEmailVerification = false;
        // The server-side sign-out path — token revoked, account removed
        // remotely — must clear the same caches the explicit paths do. Gated
        // on hadUser: see the declaration above.
        if (hadUser) {
          hadUser = false;
          _clearRiverDataCache();
        }
        AppLogger.info('AuthProvider', 'User signed out');
        _setCrashlyticsUserSafe('');
      }
      notifyListeners();
    });

    // Set current user if already signed in
    final firebaseUser = _authRepository.currentUser;
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

  /// Load user settings via use case
  Future<void> _loadUserSettings() async {
    if (_currentUser == null) return;

    AppLogger.debug(
        'AuthProvider', 'Loading user settings for: ${_currentUser!.uid}');
    final result = await _syncSettingsUseCase(_currentUser!.uid);

    if (result.isSuccess) {
      _currentUserSettings = result.data;
      AppLogger.info('AuthProvider', 'User settings loaded successfully');

      // Listeners are needed by ANY notification the user can receive, not
      // just flood alerts.
      //
      // ADR 0008 defect, carried into ADR 0011's Phase 9 list: this was gated
      // on `enableNotifications` alone. A user who turned flood alerts OFF but
      // left the Weekly Outlook ON still receives a notification every Friday
      // — and with no listeners registered, tapping it opened the app to
      // wherever it was last, instead of routing to the digest. The token was
      // never refreshed for them either, so their weekly could eventually stop
      // arriving at all.
      //
      // The two settings are independent by design (Weekly Outlook shipped
      // with its own toggle), so the gate has to be the union.
      if (wantsAnyNotification(_currentUserSettings)) {
        AppLogger.debug(
            'AuthProvider',
            'Notifications reachable (alerts: '
                '${_currentUserSettings?.enableNotifications}, weekly: '
                '${_currentUserSettings?.weeklyOutlookEnabled}), '
                'setting up listeners');
        _fcmService.setupNotificationListeners();
        await _fcmService.refreshTokenIfNeeded(_currentUser!.uid);
      }
    } else {
      AppLogger.error(
          'AuthProvider', 'Error loading user settings: ${result.errorMessage}');
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

    final result = await _signInUseCase(email: email, password: password);

    _setLoading(false);

    if (result.isSuccess) {
      return true;
    } else {
      _setError(result.errorMessage ?? 'Sign in failed');
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

    final result = await _signUpUseCase(
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
      _setError(result.errorMessage ?? 'Registration failed');
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

    final result = await _resetPasswordUseCase(email: email);

    _setLoading(false);

    if (result.isSuccess) {
      _setSuccess('Password reset email sent');
      return true;
    } else {
      _setError(result.errorMessage ?? 'Failed to send reset email');
      return false;
    }
  }

  /// Release the ADR 0011 store listeners on identity change.
  ///
  /// Round 1, B5: without this, signing out left the Firestore listeners
  /// attached. They then hit PERMISSION_DENIED under firestore.rules and died,
  /// and because the favourite set was unchanged the next sync saw an equal
  /// set and never re-subscribed — the store silently off for the rest of the
  /// session, on exactly the two-accounts-one-device path guard 2 cares about.
  void _detachStoreListeners() {
    if (!GetIt.I.isRegistered<StoreSubscriptionService>()) return;
    try {
      // detach, not dispose: the same service must serve the next sign-in.
      unawaited(GetIt.I<StoreSubscriptionService>().detach());
    } catch (e) {
      AppLogger.warning('AuthProvider', 'store detach failed: $e');
    }
  }

  /// Drop the river-data cache and its pins on any identity change: cached
  /// data is not sensitive, but the PINS belong to the account — carried over,
  /// they shield the previous user's favourites from the next user's retention
  /// cap (ADR 0011 Phase 2). ONE helper for the whole class of exits: signOut,
  /// deleteAccount, and the server-side auth-state drop. A Phase 2 review
  /// round found the first fix applied to signOut alone, with deleteAccount's
  /// own comment promising a mirror it did not perform.
  void _clearRiverDataCache() {
    _detachStoreListeners();
    if (GetIt.I.isRegistered<IRiverDataCache>()) {
      unawaited(GetIt.I<IRiverDataCache>().clear());
    }
  }

  Future<void> signOut() async {
    _setLoading(true);

    // Unregister this device's push token from the user's doc BEFORE signing
    // out — Firestore rules require the user still be authed. Otherwise the
    // token lingers in this account and gets re-added to the next account that
    // logs in on this device, leaking one user's flood alerts to another.
    final signingOutUid = _currentUser?.uid;
    if (signingOutUid != null) {
      await _fcmService.unregisterDeviceToken(signingOutUid);
    }

    final result = await _signOutUseCase();

    _setLoading(false);

    if (result.isSuccess) {
      // Clear biometric cache, user settings, and FCM token cache
      _biometricAvailable = null;
      _biometricEnabled = null;
      _currentUserSettings = null;
      _fcmService.clearCache();
      _clearRiverDataCache();
      _setSuccess('Signed out successfully');
    } else {
      _setError(result.errorMessage ?? 'Sign out failed');
    }
  }

  /// Permanently delete the currently signed-in account.
  ///
  /// Required by App Store Review Guideline 5.1.1(v). Returns `true` on
  /// success; on failure, sets [errorMessage] and returns `false`. The
  /// repository handles reauth + Firestore/FCM/Auth cleanup atomically.
  Future<bool> deleteAccount(String password) async {
    if (password.isEmpty) {
      _setError('Please enter your password to confirm account deletion');
      return false;
    }

    _setLoading(true);
    _clearMessages();

    final result = await _deleteAccountUseCase(password: password);

    _setLoading(false);

    if (result.isSuccess) {
      // Mirror signOut's cleanup — auth-state stream will drop _currentUser
      // automatically, but local caches still need clearing.
      _biometricAvailable = null;
      _biometricEnabled = null;
      _currentUserSettings = null;
      _fcmService.clearCache();
      _clearRiverDataCache();
      _setSuccess('Account deleted');
      return true;
    } else {
      _setError(result.errorMessage ?? 'Account deletion failed');
      return false;
    }
  }

  // MARK: - Email Verification

  /// Send verification email to current user
  Future<bool> sendVerificationEmail() async {
    _setLoading(true);
    _clearMessages();

    final result = await _authRepository.sendEmailVerification();

    _setLoading(false);

    if (result.isSuccess) {
      _setSuccess('Verification email sent. Check your inbox.');
      return true;
    } else {
      _setError(result.errorMessage ?? 'Failed to send verification email');
      return false;
    }
  }

  /// Check if current user's email has been verified (retries up to 3 times)
  Future<bool> checkEmailVerified() async {
    _setLoading(true);
    _clearMessages();

    // Retry up to 3 times with increasing delay to handle propagation lag
    for (int attempt = 1; attempt <= 3; attempt++) {
      final result = await _authRepository.checkEmailVerified();

      if (result.isSuccess && result.data) {
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
    _biometricAvailable ??= await _authRepository.isBiometricAvailable();
    return _biometricAvailable!;
  }

  /// Check if biometric login is enabled
  Future<bool> get isBiometricEnabled async {
    _biometricEnabled ??= await _authRepository.isBiometricEnabled();
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

    final result = await _enableBiometricUseCase();

    _setLoading(false);

    if (result.isSuccess) {
      _biometricEnabled = true; // Update cache
      _setSuccess('Biometric login enabled');
      return true;
    } else {
      _setError(result.errorMessage ?? 'Failed to enable biometric login');
      return false;
    }
  }

  /// Disable biometric login
  Future<bool> disableBiometric() async {
    _setLoading(true);
    _clearMessages();

    final result = await _disableBiometricUseCase();

    _setLoading(false);

    if (result.isSuccess) {
      _biometricEnabled = false; // Update cache
      _setSuccess('Biometric login disabled');
      return true;
    } else {
      _setError(result.errorMessage ?? 'Failed to disable biometric login');
      return false;
    }
  }

  /// Sign in with biometrics
  Future<bool> signInWithBiometric() async {
    _setLoading(true);
    _clearMessages();

    final result = await _signInWithBiometricsUseCase();

    _setLoading(false);

    if (result.isSuccess) {
      _setSuccess('Biometric sign in successful');
      return true;
    } else {
      _setError(result.errorMessage ?? 'Biometric sign in failed');
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

  /// Set the Crashlytics user identifier, swallowing any failure (e.g.
  /// `[core/no-app]` when Firebase isn't initialized — happens in
  /// integration tests and would otherwise crash the auth-state stream).
  /// Observability must never break core auth flow.
  void _setCrashlyticsUserSafe(String uid) {
    try {
      FirebaseCrashlytics.instance.setUserIdentifier(uid);
    } catch (e) {
      AppLogger.debug(
        'AuthProvider',
        'Skipped Crashlytics.setUserIdentifier (not initialized): $e',
      );
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
