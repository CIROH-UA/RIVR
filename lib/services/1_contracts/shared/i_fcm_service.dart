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
}

/// Interface for Firebase Cloud Messaging operations
abstract class IFCMService {
  /// Set the navigator key for notification-tap navigation.
  /// Must be called before [initialize] so cold-start taps can route.
  set navigatorKey(GlobalKey<NavigatorState> key);

  Future<bool> initialize();
  Future<bool> requestPermission();

  /// Set up notification tap listeners and clear the iOS badge.
  /// Call on every app launch for users with notifications enabled.
  void setupNotificationListeners();
  Future<String?> getAndSaveToken(String userId);
  Future<NotificationPermissionResult> enableNotifications(String userId);
  Future<void> disableNotifications(String userId);
  Future<bool> isEnabledForUser(String userId);
  Future<void> refreshTokenIfNeeded(String userId);
  void clearCache();
}
