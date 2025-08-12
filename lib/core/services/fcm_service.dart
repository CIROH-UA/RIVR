// lib/core/services/fcm_service.dart

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:rivrflow/core/services/error_service.dart';
import 'package:rivrflow/features/auth/services/user_settings_service.dart';

/// Simple FCM service for managing push notification tokens
/// Integrates with existing UserSettingsService
class FCMService {
  static final FCMService _instance = FCMService._internal();
  factory FCMService() => _instance;
  FCMService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final UserSettingsService _userSettingsService = UserSettingsService();

  bool _isInitialized = false;
  String? _cachedToken;

  /// Initialize FCM - call this when user enables notifications
  Future<bool> initialize() async {
    try {
      print('FCM_SERVICE: Initializing Firebase Messaging');

      // Request permission first
      final permissionGranted = await requestPermission();
      if (!permissionGranted) {
        print('FCM_SERVICE: Permission denied, cannot initialize');
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
      print('FCM_SERVICE: Successfully initialized');
      return true;
    } catch (e) {
      print('FCM_SERVICE: Initialization error: $e');
      ErrorService.logError('FCMService.initialize', e);
      return false;
    }
  }

  /// Request notification permissions
  Future<bool> requestPermission() async {
    try {
      print('FCM_SERVICE: Requesting notification permission');

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

      print('FCM_SERVICE: Permission status: ${settings.authorizationStatus}');
      return isAuthorized;
    } catch (e) {
      print('FCM_SERVICE: Error requesting permission: $e');
      ErrorService.logError('FCMService.requestPermission', e);
      return false;
    }
  }

  /// Get FCM token and save to user settings
  Future<String?> getAndSaveToken(String userId) async {
    try {
      print('FCM_SERVICE: Getting FCM token for user: $userId');

      // Return cached token if available
      if (_cachedToken != null) {
        print('FCM_SERVICE: Using cached token');
        return _cachedToken;
      }

      // Get fresh token
      final token = await _messaging.getToken();
      if (token == null) {
        print('FCM_SERVICE: Failed to get FCM token');
        return null;
      }

      print('FCM_SERVICE: Got FCM token: ${token.substring(0, 20)}...');
      _cachedToken = token;

      // Save token to user settings
      await _saveTokenToUserSettings(userId, token);

      return token;
    } catch (e) {
      print('FCM_SERVICE: Error getting token: $e');
      ErrorService.logError('FCMService.getAndSaveToken', e);
      return null;
    }
  }

  /// Save FCM token to UserSettings
  Future<void> _saveTokenToUserSettings(String userId, String token) async {
    try {
      print('FCM_SERVICE: Saving token to user settings');

      final currentSettings = await _userSettingsService.getUserSettings(
        userId,
      );
      if (currentSettings == null) {
        print('FCM_SERVICE: No user settings found, cannot save token');
        return;
      }

      // Update settings with new FCM token
      final updatedSettings = currentSettings.copyWith(fcmToken: token);
      await _userSettingsService.saveUserSettings(updatedSettings);

      print('FCM_SERVICE: Token saved to user settings');
    } catch (e) {
      print('FCM_SERVICE: Error saving token to settings: $e');
      ErrorService.logError('FCMService._saveTokenToUserSettings', e);
    }
  }

  /// Handle foreground messages (when app is open)
  void _handleForegroundMessage(RemoteMessage message) {
    print('FCM_SERVICE: Received foreground message: ${message.messageId}');
    print('FCM_SERVICE: Title: ${message.notification?.title}');
    print('FCM_SERVICE: Body: ${message.notification?.body}');

    // For now, just log. In the future, you could show an in-app notification
    // or update the UI to reflect new flood conditions
  }

  /// Handle notification tap (when user taps notification)
  void _handleNotificationTap(RemoteMessage message) {
    print('FCM_SERVICE: Notification tapped: ${message.messageId}');
    print('FCM_SERVICE: Data: ${message.data}');

    // Handle navigation based on notification data
    final reachId = message.data['reachId'];
    if (reachId != null) {
      print('FCM_SERVICE: Should navigate to reach: $reachId');
      // TODO: Add navigation logic when needed
      // Could use a global navigator key or callback
    }
  }

  /// Enable notifications for a user (gets token and saves it)
  Future<bool> enableNotifications(String userId) async {
    try {
      print('FCM_SERVICE: Enabling notifications for user: $userId');

      // Initialize if not already done
      if (!_isInitialized) {
        final initialized = await initialize();
        if (!initialized) return false;
      }

      // Get and save token
      final token = await getAndSaveToken(userId);
      return token != null;
    } catch (e) {
      print('FCM_SERVICE: Error enabling notifications: $e');
      ErrorService.logError('FCMService.enableNotifications', e);
      return false;
    }
  }

  /// Disable notifications for a user (clears token)
  Future<void> disableNotifications(String userId) async {
    try {
      print('FCM_SERVICE: Disabling notifications for user: $userId');

      // Clear cached token
      _cachedToken = null;

      // Remove token from user settings
      final currentSettings = await _userSettingsService.getUserSettings(
        userId,
      );
      if (currentSettings != null) {
        final updatedSettings = currentSettings.copyWith(fcmToken: null);
        await _userSettingsService.saveUserSettings(updatedSettings);
        print('FCM_SERVICE: Token removed from user settings');
      }

      // Delete token from Firebase (optional - prevents old tokens from being used)
      await _messaging.deleteToken();
      print('FCM_SERVICE: Token deleted from Firebase');
    } catch (e) {
      print('FCM_SERVICE: Error disabling notifications: $e');
      ErrorService.logError('FCMService.disableNotifications', e);
    }
  }

  /// Check if notifications are properly set up for user
  Future<bool> isEnabledForUser(String userId) async {
    try {
      final settings = await _userSettingsService.getUserSettings(userId);
      return settings?.hasValidFCMToken ?? false;
    } catch (e) {
      print('FCM_SERVICE: Error checking notification status: $e');
      return false;
    }
  }

  /// Refresh token if needed (call on app startup)
  Future<void> refreshTokenIfNeeded(String userId) async {
    try {
      // Listen for token refresh (happens when app is restored from backup, etc.)
      _messaging.onTokenRefresh.listen((newToken) async {
        print('FCM_SERVICE: Token refreshed: ${newToken.substring(0, 20)}...');
        _cachedToken = newToken;
        await _saveTokenToUserSettings(userId, newToken);
      });
    } catch (e) {
      print('FCM_SERVICE: Error setting up token refresh: $e');
      ErrorService.logError('FCMService.refreshTokenIfNeeded', e);
    }
  }

  /// Clear cache (call on user logout)
  void clearCache() {
    print('FCM_SERVICE: Clearing cache');
    _cachedToken = null;
    _isInitialized = false;
  }
}
