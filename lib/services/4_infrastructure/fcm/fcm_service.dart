// lib/services/4_infrastructure/fcm/fcm_service.dart

import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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

  // Local-notifications plugin, used to DISPLAY pushes while the app is in the
  // foreground on Android (FCM does not auto-display notification payloads then;
  // iOS is covered by setForegroundNotificationPresentationOptions). Reuses the
  // same `river_alerts` channel the server targets so behavior is consistent.
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _localNotificationsReady = false;

  // Matches AndroidManifest's default_notification_channel_id + server channelId.
  static const _androidChannelId = 'river_alerts';
  static const _androidChannelName = 'River Alerts';
  static const _androidChannelDescription =
      'Flood alerts for your favorite rivers';

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

    // Prepare local notifications so foreground pushes can be displayed on
    // Android (fire-and-forget; ready well before the first alert arrives).
    _initLocalNotifications();

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

  /// On iOS the APNS token must be available before FCM will hand out a token.
  /// Polls for it (3 × 2s). Returns true once ready, false if it never arrives
  /// (simulator or a provisioning issue). No-op / true on Android.
  Future<bool> _ensureApnsReady() async {
    if (!Platform.isIOS) return true;
    AppLogger.debug('FcmService', 'Waiting for APNS token (iOS requirement)');
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final apnsToken = await _messaging.getAPNSToken();
        if (apnsToken != null) {
          AppLogger.debug('FcmService', 'APNS token obtained on attempt ${attempt + 1}');
          return true;
        }
      } catch (_) {
        // Ignore errors, just retry
      }
      AppLogger.debug('FcmService', 'APNS token not ready, waiting... (attempt ${attempt + 1}/3)');
      await Future.delayed(const Duration(seconds: 2));
    }
    AppLogger.warning('FcmService', 'APNS token not available (simulator or provisioning issue)');
    return false;
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
    if (!await _ensureApnsReady()) {
      return 'pending';
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

  /// The current device's FCM token for *removal* purposes (logout / disable).
  /// Uses the cached token when present, otherwise fetches it — waiting for the
  /// APNS token on iOS — so we can prune it from Firestore even on a fresh
  /// launch where nothing has populated the cache yet. Returns null if the
  /// device has no deliverable token (simulator / not provisioned).
  Future<String?> _currentDeviceToken() async {
    if (_cachedToken != null && _cachedToken != 'pending') return _cachedToken;
    try {
      if (!await _ensureApnsReady()) return null;
      return await _messaging.getToken();
    } catch (e) {
      AppLogger.debug('FcmService', 'Could not resolve current device token: $e');
      return null;
    }
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
        'fcmTokens': FieldValue.arrayUnion([token]),
      });
      AppLogger.info('FcmService', 'Token saved to user settings');
    } catch (e) {
      AppLogger.error('FcmService', 'Error saving token to settings: $e', e);
      ErrorService.logError('FCMService._saveTokenToUserSettings', e);
    }
  }

  /// Initialize the local-notifications plugin and (Android) create the alert
  /// channel. iOS permissions are owned by FCM, so we request none here and only
  /// ever display foreground notifications on Android.
  Future<void> _initLocalNotifications() async {
    if (_localNotificationsReady) return;
    try {
      const androidInit = AndroidInitializationSettings('ic_notification');
      const iosInit = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _localNotifications.initialize(
        const InitializationSettings(android: androidInit, iOS: iosInit),
        onDidReceiveNotificationResponse: _onLocalNotificationTap,
      );

      // Ensure the channel exists (Android 8+). Matches the server's channelId.
      const channel = AndroidNotificationChannel(
        _androidChannelId,
        _androidChannelName,
        description: _androidChannelDescription,
        importance: Importance.high,
      );
      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      _localNotificationsReady = true;
      AppLogger.debug('FcmService', 'Local notifications ready');
    } catch (e) {
      AppLogger.error('FcmService', 'Local notifications init failed: $e', e);
    }
  }

  /// Tap on a locally-displayed (foreground) notification → route to the reach.
  void _onLocalNotificationTap(NotificationResponse response) {
    final reachId = response.payload;
    if (reachId != null && reachId.isNotEmpty) {
      _navigateToReach(reachId);
    }
  }

  /// Handle foreground messages (when app is open).
  ///
  /// iOS displays them itself via setForegroundNotificationPresentationOptions.
  /// Android does NOT auto-display FCM notification payloads while foregrounded,
  /// so we render one ourselves through flutter_local_notifications, carrying
  /// the reachId as the payload so a tap routes to the forecast.
  void _handleForegroundMessage(RemoteMessage message) {
    final notification = message.notification;
    AppLogger.debug('FcmService', 'Received foreground message: ${message.messageId}');

    if (notification == null || !Platform.isAndroid) return;

    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannelId,
          _androidChannelName,
          channelDescription: _androidChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_notification',
          color: Color(0xFFFF6B35),
        ),
      ),
      payload: message.data['reachId'] as String?,
    );
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
        // Normal path: add token to array + flag + frequency together
        await _userSettingsService.updateUserSettings(userId, {
          'fcmTokens': FieldValue.arrayUnion([token]),
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

      // Remove this device's token from the array. Resolve it even on a fresh
      // launch (cache empty) so we don't leave an orphaned token behind.
      final tokenToRemove = await _currentDeviceToken();
      _cachedToken = null;

      final updates = <String, dynamic>{
        'enableNotifications': false,
      };
      if (tokenToRemove != null && tokenToRemove != 'pending') {
        updates['fcmTokens'] = FieldValue.arrayRemove([tokenToRemove]);
      }
      await _userSettingsService.updateUserSettings(userId, updates);
      AppLogger.info('FcmService', 'Token removed and notifications disabled');

      // Delete token from Firebase (prevents old tokens from being used).
      // Best-effort: if there's no APNS token (iOS simulator, push not
      // provisioned, or token not yet delivered) there's nothing to delete —
      // that's a benign no-op, not a crash worth reporting to Crashlytics.
      try {
        await _messaging.deleteToken();
        AppLogger.info('FcmService', 'Token deleted from Firebase');
      } catch (e) {
        AppLogger.debug(
          'FcmService',
          'Skipped token deletion (no token to delete): $e',
        );
      }
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

      // iOS: FCM won't return a token until APNS is ready. Skipping this wait is
      // a race that can leave a returning iOS user unregistered for the session.
      if (!await _ensureApnsReady()) {
        AppLogger.warning('FcmService', 'APNS not ready; deferring token refresh');
        return;
      }

      // Get the current token from Firebase
      final freshToken = await _messaging.getToken();
      if (freshToken == null) {
        AppLogger.warning('FcmService', 'Could not get fresh FCM token');
        return;
      }

      // Update Firestore if the token has changed
      if (freshToken != _cachedToken) {
        AppLogger.info('FcmService', 'FCM token changed, updating Firestore');
        final oldToken = _cachedToken;
        _cachedToken = freshToken;

        // Remove old token and add new one atomically
        if (oldToken != null) {
          await _userSettingsService.updateUserSettings(userId, {
            'fcmTokens': FieldValue.arrayRemove([oldToken]),
          });
        }
        await _saveTokenToUserSettings(userId, freshToken);
      } else {
        AppLogger.debug('FcmService', 'FCM token unchanged');
      }

      // Listen for future token rotations (only register once)
      _tokenRefreshSubscription ??= _messaging.onTokenRefresh.listen((newToken) async {
        AppLogger.debug('FcmService', 'Token refreshed: ${newToken.substring(0, 20)}...');
        final oldToken = _cachedToken;
        _cachedToken = newToken;

        if (oldToken != null) {
          await _userSettingsService.updateUserSettings(userId, {
            'fcmTokens': FieldValue.arrayRemove([oldToken]),
          });
        }
        await _saveTokenToUserSettings(userId, newToken);
      });
    } catch (e) {
      AppLogger.error('FcmService', 'Error refreshing token: $e', e);
      ErrorService.logError('FCMService.refreshTokenIfNeeded', e);
    }
  }

  /// Unregister THIS device's token from the given user's Firestore doc on
  /// logout, without touching `enableNotifications` (their other devices should
  /// keep working). Prevents the token from lingering in the previous account
  /// and being re-added to the next account on this device — which would leak
  /// one user's alerts to another. Call this while [userId] is still authed,
  /// before [clearCache].
  @override
  Future<void> unregisterDeviceToken(String userId) async {
    try {
      final token = await _currentDeviceToken();
      if (token != null && token != 'pending') {
        await _userSettingsService.updateUserSettings(userId, {
          'fcmTokens': FieldValue.arrayRemove([token]),
        });
        AppLogger.info('FcmService', 'Unregistered device token on logout');
      }
      // Invalidate the token on this device so a new install/account gets a
      // fresh one. Best-effort — a missing token is a benign no-op.
      try {
        await _messaging.deleteToken();
      } catch (e) {
        AppLogger.debug('FcmService', 'Skipped token deletion on logout: $e');
      }
    } catch (e) {
      AppLogger.error('FcmService', 'Error unregistering device token: $e', e);
      ErrorService.logError('FCMService.unregisterDeviceToken', e);
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
