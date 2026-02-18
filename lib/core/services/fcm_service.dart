// lib/services/fcm_service.dart

import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:rivr/core/services/error_service.dart';
import 'app_logger.dart';
import 'package:rivr/features/auth/services/i_user_settings_service.dart';
import 'i_fcm_service.dart';

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

      // Set up foreground message handling
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Set up notification tap handling
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

      // Handle notification that opened the app (cold start)
      final initialMessage = await _messaging.getInitialMessage();
      if (initialMessage != null) {
        _handleNotificationTap(initialMessage);
      }

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

  /// Get FCM token and save to user settings
  @override
  Future<String?> getAndSaveToken(String userId) async {
    try {
      AppLogger.debug('FcmService', 'Getting FCM token for user: $userId');

      // Return cached token if available
      if (_cachedToken != null) {
        AppLogger.debug('FcmService', 'Using cached token');
        return _cachedToken;
      }

      // iOS: Get APNS token first (required)
      if (Platform.isIOS) {
        AppLogger.debug('FcmService', 'Getting APNS token first (iOS requirement)');
        try {
          final apnsToken = await _messaging.getAPNSToken();
          if (apnsToken != null) {
            AppLogger.debug(
              'FcmService',
              'APNS token obtained: ${apnsToken.substring(0, 20)}...',
            );
          } else {
            AppLogger.warning('FcmService', 'APNS token is null, continuing anyway...');
          }
        } catch (e) {
          AppLogger.error('FcmService', 'Error getting APNS token: $e', e);
          // Continue anyway - sometimes this works without explicit APNS token
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

      // Save token to user settings
      await _saveTokenToUserSettings(userId, token);

      return token;
    } catch (e) {
      AppLogger.error('FcmService', 'Error getting token: $e', e);
      ErrorService.logError('FCMService.getAndSaveToken', e);
      return null;
    }
  }

  /// Save FCM token to UserSettings
  Future<void> _saveTokenToUserSettings(String userId, String token) async {
    try {
      AppLogger.debug('FcmService', 'Saving token to user settings');

      final currentSettings = await _userSettingsService.getUserSettings(
        userId,
      );
      if (currentSettings == null) {
        AppLogger.warning('FcmService', 'No user settings found, cannot save token');
        return;
      }

      // Update settings with new FCM token
      final updatedSettings = currentSettings.copyWith(fcmToken: token);
      await _userSettingsService.saveUserSettings(updatedSettings);

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

    // For now, just log. In the future, you could show an in-app notification
    // or update the UI to reflect new flood conditions
  }

  /// Handle notification tap (when user taps notification)
  void _handleNotificationTap(RemoteMessage message) {
    AppLogger.debug('FcmService', 'Notification tapped: ${message.messageId}');
    AppLogger.debug('FcmService', 'Data: ${message.data}');

    // Handle navigation based on notification data
    final reachId = message.data['reachId'];
    if (reachId != null) {
      AppLogger.debug('FcmService', 'Should navigate to reach: $reachId');
      // TODO: Add navigation logic when needed
      // Could use a global navigator key or callback
    }
  }

  /// Enable notifications for a user (gets token and saves it)
  @override
  Future<bool> enableNotifications(String userId) async {
    try {
      AppLogger.debug('FcmService', 'Enabling notifications for user: $userId');

      // Initialize if not already done
      if (!_isInitialized) {
        final initialized = await initialize();
        if (!initialized) return false;
      }

      // Get and save token
      final token = await getAndSaveToken(userId);
      return token != null;
    } catch (e) {
      AppLogger.error('FcmService', 'Error enabling notifications: $e', e);
      ErrorService.logError('FCMService.enableNotifications', e);
      return false;
    }
  }

  /// Disable notifications for a user (clears token)
  @override
  Future<void> disableNotifications(String userId) async {
    try {
      AppLogger.debug('FcmService', 'Disabling notifications for user: $userId');

      // Clear cached token
      _cachedToken = null;

      // Remove token from user settings
      final currentSettings = await _userSettingsService.getUserSettings(
        userId,
      );
      if (currentSettings != null) {
        final updatedSettings = currentSettings.copyWith(fcmToken: null);
        await _userSettingsService.saveUserSettings(updatedSettings);
        AppLogger.info('FcmService', 'Token removed from user settings');
      }

      // Delete token from Firebase (optional - prevents old tokens from being used)
      await _messaging.deleteToken();
      AppLogger.info('FcmService', 'Token deleted from Firebase');
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
  @override
  Future<void> refreshTokenIfNeeded(String userId) async {
    try {
      // Listen for token refresh (happens when app is restored from backup, etc.)
      _messaging.onTokenRefresh.listen((newToken) async {
        AppLogger.debug('FcmService', 'Token refreshed: ${newToken.substring(0, 20)}...');
        _cachedToken = newToken;
        await _saveTokenToUserSettings(userId, newToken);
      });
    } catch (e) {
      AppLogger.error('FcmService', 'Error setting up token refresh: $e', e);
      ErrorService.logError('FCMService.refreshTokenIfNeeded', e);
    }
  }

  /// Clear cache (call on user logout)
  @override
  void clearCache() {
    AppLogger.debug('FcmService', 'Clearing cache');
    _cachedToken = null;
    _isInitialized = false;
  }
}
