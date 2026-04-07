// lib/services/4_infrastructure/shared/analytics_service.dart

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Thin singleton wrapper around FirebaseAnalytics.
///
/// All event names and parameter keys are defined here so they stay
/// consistent across the codebase. Call sites never import FirebaseAnalytics
/// directly — they call AnalyticsService methods.
///
/// Guards every call with [Firebase.apps.isNotEmpty] so tests that don't
/// initialize Firebase stay safe.
class AnalyticsService {
  AnalyticsService._internal();
  static final AnalyticsService instance = AnalyticsService._internal();

  FirebaseAnalytics get _analytics => FirebaseAnalytics.instance;

  bool get _ready => Firebase.apps.isNotEmpty;

  // ─── Favorites ────────────────────────────────────────────────────────────

  Future<void> logFavoriteAdded(String reachId) async {
    if (!_ready) return;
    try {
      await _analytics.logEvent(
        name: 'favorite_added',
        parameters: {'reach_id': reachId},
      );
    } catch (e) {
      AppLogger.warning('AnalyticsService', 'logFavoriteAdded failed: $e');
    }
  }

  Future<void> logFavoriteRemoved(String reachId) async {
    if (!_ready) return;
    try {
      await _analytics.logEvent(
        name: 'favorite_removed',
        parameters: {'reach_id': reachId},
      );
    } catch (e) {
      AppLogger.warning('AnalyticsService', 'logFavoriteRemoved failed: $e');
    }
  }

  // ─── Forecast ─────────────────────────────────────────────────────────────

  Future<void> logForecastLoaded(String reachId, {bool fromCache = false}) async {
    if (!_ready) return;
    try {
      await _analytics.logEvent(
        name: 'forecast_loaded',
        parameters: {
          'reach_id': reachId,
          'from_cache': fromCache ? 'true' : 'false',
        },
      );
    } catch (e) {
      AppLogger.warning('AnalyticsService', 'logForecastLoaded failed: $e');
    }
  }

  // ─── Notifications ────────────────────────────────────────────────────────

  Future<void> logNotificationsEnabled() async {
    if (!_ready) return;
    try {
      await _analytics.logEvent(name: 'notifications_enabled');
    } catch (e) {
      AppLogger.warning('AnalyticsService', 'logNotificationsEnabled failed: $e');
    }
  }

  Future<void> logNotificationsDisabled() async {
    if (!_ready) return;
    try {
      await _analytics.logEvent(name: 'notifications_disabled');
    } catch (e) {
      AppLogger.warning('AnalyticsService', 'logNotificationsDisabled failed: $e');
    }
  }

  // ─── Navigation (screen views) ────────────────────────────────────────────

  /// Returns an observer to pass to [CupertinoApp.navigatorObservers].
  /// Automatically logs a screen_view event on every named route transition.
  FirebaseAnalyticsObserver get observer =>
      FirebaseAnalyticsObserver(analytics: _analytics);
}
