// lib/services/1_contracts/shared/i_fcm_service.dart

import 'package:flutter/widgets.dart';

/// Result of a notification permission request
enum NotificationPermissionResult {
  /// Permission was granted (or was already granted)
  granted,

  /// Permission was denied but can still be requested again
  denied,

  /// Permission was permanently denied — user must enable via system settings
  permanentlyDenied,

  /// An error occurred while requesting permission
  error,

  /// The OS has not been asked yet — no prompt has been shown on this device.
  /// Distinct from [denied]: the one system prompt is still available.
  notDetermined,
}

/// Interface for Firebase Cloud Messaging operations
abstract class IFCMService {
  /// Set the navigator key for notification-tap navigation.
  /// Must be called before [initialize] so cold-start taps can route.
  set navigatorKey(GlobalKey<NavigatorState> key);

  Future<bool> initialize();
  Future<bool> requestPermission();

  /// The OS-level notification permission **on this device**, read without
  /// showing a prompt.
  ///
  /// This exists because a stored preference is not permission. Settings sync
  /// through Firestore, so signing in on a second device renders the toggles
  /// ON while that device has never been asked — and since the app only
  /// requests permission when a toggle is *switched* on, it never asks. The
  /// user then sees "enabled" on a device the OS will not let post anything.
  /// Measured on Android: `POST_NOTIFICATIONS granted=false` with both toggles
  /// green and a registered FCM token (tokens do not require the permission).
  Future<NotificationPermissionResult> osPermissionStatus();

  /// Set up notification tap listeners and clear the iOS badge.
  /// Call on every app launch for users with notifications enabled.
  void setupNotificationListeners();
  Future<String?> getAndSaveToken(String userId);
  /// Enable/disable Flood Alerts (threshold pushes).
  Future<NotificationPermissionResult> enableNotifications(String userId);
  Future<void> disableNotifications(String userId);

  /// Enable/disable the Weekly Outlook digest — an independent notification
  /// type. A device token is registered while either type is on and removed
  /// only when both are off.
  Future<NotificationPermissionResult> enableWeeklyOutlook(String userId);
  Future<void> disableWeeklyOutlook(String userId);
  Future<bool> isEnabledForUser(String userId);
  Future<void> refreshTokenIfNeeded(String userId);

  /// Remove this device's token from [userId]'s Firestore doc on logout, without
  /// disabling notifications account-wide. Call while [userId] is still authed,
  /// before [clearCache], to avoid leaking one account's alerts to the next.
  Future<void> unregisterDeviceToken(String userId);

  void clearCache();
}
