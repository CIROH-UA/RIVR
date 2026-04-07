// lib/services/4_infrastructure/fcm/fcm_service.dart

import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:rivr/ui/2_presentation/routing/app_routes.dart';
import 'package:rivr/services/4_infrastructure/shared/error_service.dart';
import 'package:rivr/services/4_infrastructure/shared/analytics_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';

/// Simple FCM service for managing push notification tokens
/// Integrates with existing UserSettingsService
class FCMService implements IFCMService {
  final FirebaseMessaging _messaging;
  final IUserSettingsService _userSettingsService;

  FCMService({
    FirebaseMessaging? messaging,
    required IUserSettingsService settingsService,
  })  : _messaging = messaging ?? FirebaseMessaging.instance,
        _userSettingsService = settingsService;

  bool _isInitialized = false;
  String? _cachedToken;
  StreamSubscription<String>? _tokenRefreshSubscription;
  GlobalKey<NavigatorState>? _navigatorKey;

  @override
  set navigatorKey(GlobalKey<NavigatorState> key) => _navigatorKey = key;

  bool _listenersRegistered = false;

  /// Set up notification tap listeners and clear the iOS badge.
  /// Safe to call multiple times — listeners are only registered once.
  @override
  void setupNotificationListeners() {
    if (_listenersRegistered) return;
    _listenersRegistered = true;

    AppLogger.debug('FcmService', 'Setting up notification listeners');

    // Foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Notification tap while app was in background
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // Cold-start: notification tap that launched the app
    _messaging.getInitialMessage().then((message) {
      if (message != null) {
        _handleNotificationTap(message);
      }
    });

    // Clear iOS badge on launch
    if (Platform.isIOS) {
      _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }
  }

  /// Initialize FCM - call this when user enables notifications
  @override
  Future<bool> initialize() async {
    try {
      AppLogger.debug('FcmService', 'Initializing Firebase Messaging');

      // Request permission first
      final permissionGranted = await requestPermission();
      if (!permissionGranted) {
        AppLogger.warning('FcmService', 'Permission denied, cannot initialize');
        return false;
      }

      // Ensure listeners are set up
      setupNotificationListeners();

      _isInitialized = true;
      AppLogger.info('FcmService', 'Successfully initialized');
      return true;
    } catch (e) {
      AppLogger.error('FcmService', 'Initialization error: $e', e);
      ErrorService.logError('FCMService.initialize', e);
      return false;
    }
  }

  /// Request notification permissions
  @override
  Future<bool> requestPermission() async {
    try {
      AppLogger.debug('FcmService', 'Requesting notification permission');

      final settings = await _messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      final isAuthorized =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;

      AppLogger.debug('FcmService', 'Permission status: ${settings.authorizationStatus}');
      return isAuthorized;
    } catch (e) {
      AppLogger.error('FcmService', 'Error requesting permission: $e', e);
      ErrorService.logError('FCMService.requestPermission', e);
      return false;
    }
  }

  /// Retrieve the FCM token without saving it.
  /// Returns the token string, 'pending' for iOS simulator, or null on failure.
  Future<String?> _getToken() async {
    // Return cached token if available
    if (_cachedToken != null) {
      AppLogger.debug('FcmService', 'Using cached token');
      return _cachedToken;
    }

    // iOS: Wait for APNS token (required before FCM token)
    if (Platform.isIOS) {
      AppLogger.debug('FcmService', 'Waiting for APNS token (iOS requirement)');
      String? apnsToken;
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          apnsToken = await _messaging.getAPNSToken();
        } catch (_) {
          // Ignore errors, just retry
        }
        if (apnsToken != null) {
          AppLogger.debug('FcmService', 'APNS token obtained on attempt ${attempt + 1}');
          break;
        }
        AppLogger.debug('FcmService', 'APNS token not ready, waiting... (attempt ${attempt + 1}/3)');
        await Future.delayed(const Duration(seconds: 2));
      }
      if (apnsToken == null) {
        AppLogger.warning('FcmService', 'APNS token not available (simulator or provisioning issue)');
        return 'pending';
      }
    }

    // Get fresh FCM token
    final token = await _messaging.getToken();
    if (token == null) {
      AppLogger.warning('FcmService', 'Failed to get FCM token');
      return null;
    }

    AppLogger.debug('FcmService', 'Got FCM token: ${token.substring(0, 20)}...');
    _cachedToken = token;
    return token;
  }

  /// Get FCM token and save to user settings
  @override
  Future<String?> getAndSaveToken(String userId) async {
    try {
      AppLogger.debug('FcmService', 'Getting FCM token for user: $userId');

      final token = await _getToken();
      if (token == null || token == 'pending') return token;

      // Save token to user settings
      await _saveTokenToUserSettings(userId, token);

      return token;
    } catch (e) {
      AppLogger.error('FcmService', 'Error getting token: $e', e);
      ErrorService.logError('FCMService.getAndSaveToken', e);
      return null;
    }
  }

  /// Save FCM token to UserSettings via partial Firestore update
  Future<void> _saveTokenToUserSettings(String userId, String token) async {
    try {
      await _userSettingsService.updateUserSettings(userId, {
        'fcmToken': token,
      });
      AppLogger.info('FcmService', 'Token saved to user settings');
    } catch (e) {
      AppLogger.error('FcmService', 'Error saving token to settings: $e', e);
      ErrorService.logError('FCMService._saveTokenToUserSettings', e);
    }
  }

  /// Handle foreground messages (when app is open)
  void _handleForegroundMessage(RemoteMessage message) {
    AppLogger.debug('FcmService', 'Received foreground message: ${message.messageId}');
    AppLogger.debug('FcmService', 'Title: ${message.notification?.title}');
    AppLogger.debug('FcmService', 'Body: ${message.notification?.body}');

    // Foreground notifications are displayed by the OS on both platforms
    // (iOS via AppDelegate willPresent, Android via FCM notification channel).
    // No in-app action needed here — the user can tap the system notification
    // and _handleNotificationTap will fire.
  }

  /// Handle notification tap (when user taps notification from background or cold start)
  void _handleNotificationTap(RemoteMessage message) {
    AppLogger.debug('FcmService', 'Notification tapped: ${message.messageId}');
    AppLogger.debug('FcmService', 'Data: ${message.data}');

    final reachId = message.data['reachId'] as String?;
    if (reachId != null && reachId.isNotEmpty) {
      _navigateToReach(reachId);
    }
  }

  /// Navigate to the forecast page for a given reach.
  void _navigateToReach(String reachId) {
    final nav = _navigatorKey?.currentState;
    if (nav == null) {
      AppLogger.warning('FcmService', 'Navigator not available, cannot route to reach: $reachId');
      return;
    }

    AppLogger.info('FcmService', 'Navigating to reach: $reachId');
    nav.pushNamed(AppRoutes.forecast, arguments: reachId);
  }

  /// Enable notifications for a user (gets token and saves it atomically with the flag)
  @override
  Future<NotificationPermissionResult> enableNotifications(String userId) async {
    try {
      AppLogger.debug('FcmService', 'Enabling notifications for user: $userId');

      // Initialize if not already done
      if (!_isInitialized) {
        final initialized = await initialize();
        if (!initialized) {
          // Check whether the denial is permanent
          final status = await _messaging.getNotificationSettings();
          if (status.authorizationStatus == AuthorizationStatus.denied) {
            return NotificationPermissionResult.permanentlyDenied;
          }
          return NotificationPermissionResult.denied;
        }
      }

      // Get the token (without saving yet)
      final token = await _getToken();
      if (token == null) {
        return NotificationPermissionResult.error;
      }

      // Write token + flag atomically in one partial update
      if (token == 'pending') {
        // iOS simulator: no device token, just save the preference
        AppLogger.info('FcmService', 'Notifications enabled (token pending — will register on real device)');
        await _userSettingsService.updateUserSettings(userId, {
          'enableNotifications': true,
          'notificationFrequency': 1,
        });
      } else {
        // Normal path: save token + flag + frequency together
        await _userSettingsService.updateUserSettings(userId, {
          'fcmToken': token,
          'enableNotifications': true,
          'notificationFrequency': 1,
        });
      }

      AnalyticsService.instance.logNotificationsEnabled();
      return NotificationPermissionResult.granted;
    } catch (e) {
      AppLogger.error('FcmService', 'Error enabling notifications: $e', e);
      ErrorService.logError('FCMService.enableNotifications', e);
      return NotificationPermissionResult.error;
    }
  }

  /// Disable notifications for a user (clears token)
  @override
  Future<void> disableNotifications(String userId) async {
    try {
      AppLogger.debug('FcmService', 'Disabling notifications for user: $userId');

      // Clear cached token
      _cachedToken = null;

      // Remove token and disable flag atomically via partial update
      await _userSettingsService.updateUserSettings(userId, {
        'fcmToken': FieldValue.delete(),
        'enableNotifications': false,
      });
      AppLogger.info('FcmService', 'Token removed and notifications disabled');

      // Delete token from Firebase (prevents old tokens from being used)
      await _messaging.deleteToken();
      AppLogger.info('FcmService', 'Token deleted from Firebase');
      AnalyticsService.instance.logNotificationsDisabled();
    } catch (e) {
      AppLogger.error('FcmService', 'Error disabling notifications: $e', e);
      ErrorService.logError('FCMService.disableNotifications', e);
    }
  }

  /// Check if notifications are properly set up for user
  @override
  Future<bool> isEnabledForUser(String userId) async {
    try {
      final settings = await _userSettingsService.getUserSettings(userId);
      return settings?.hasValidFCMToken ?? false;
    } catch (e) {
      AppLogger.error('FcmService', 'Error checking notification status: $e', e);
      return false;
    }
  }

  /// Refresh token if needed (call on app startup)
  /// Fetches a fresh FCM token, updates Firestore if it changed,
  /// and listens for future token rotations.
  @override
  Future<void> refreshTokenIfNeeded(String userId) async {
    try {
      AppLogger.debug('FcmService', 'Refreshing FCM token for user: $userId');

      // Get the current token from Firebase
      final freshToken = await _messaging.getToken();
      if (freshToken == null) {
        AppLogger.warning('FcmService', 'Could not get fresh FCM token');
        return;
      }

      // Update Firestore if the token has changed
      if (freshToken != _cachedToken) {
        AppLogger.info('FcmService', 'FCM token changed, updating Firestore');
        _cachedToken = freshToken;
        await _saveTokenToUserSettings(userId, freshToken);
      } else {
        AppLogger.debug('FcmService', 'FCM token unchanged');
      }

      // Listen for future token rotations (only register once)
      _tokenRefreshSubscription ??= _messaging.onTokenRefresh.listen((newToken) async {
        AppLogger.debug('FcmService', 'Token refreshed: ${newToken.substring(0, 20)}...');
        _cachedToken = newToken;
        await _saveTokenToUserSettings(userId, newToken);
      });
    } catch (e) {
      AppLogger.error('FcmService', 'Error refreshing token: $e', e);
      ErrorService.logError('FCMService.refreshTokenIfNeeded', e);
    }
  }

  /// Clear cache (call on user logout)
  @override
  void clearCache() {
    AppLogger.debug('FcmService', 'Clearing cache');
    _cachedToken = null;
    _isInitialized = false;
    _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
  }
}
