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

  /// Permission is fine, but no device token could be obtained — APNs not
  /// ready, or a failed write. The device cannot receive anything, so the
  /// caller must NOT persist a preference on the strength of this.
  tokenUnavailable,

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

  /// Bring THIS device into line with the account's preference.
  ///
  /// Preferences sync through Firestore; permissions do not. A device signing
  /// in to an account that already wants notifications inherits the preference
  /// with a blank permission, and because the app only asks when a toggle is
  /// *switched*, an inherited "on" is never asked about. This closes that gap.
  ///
  /// [wantsAny] is the account preference — true when either notification type
  /// is on. Call from a context where a permission prompt makes sense to the
  /// user; never at cold launch.
  ///
  /// Asks at most **once per app session** and never when already denied, so it
  /// is safe to call on every build.
  Future<NotificationPermissionResult> reconcileDevice(
    String userId, {
    required bool wantsAny,
  });

  /// Set up notification tap listeners and foreground presentation options.
  ///
  /// Does NOT clear the app icon badge — that is
  /// applicationDidBecomeActive in ios/Runner/AppDelegate.swift. This comment
  /// claimed otherwise, and the badge went unfixed behind it.
  /// Call on every app launch for users with notifications enabled.
  void setupNotificationListeners();
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
