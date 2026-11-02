// lib/services/4_infrastructure/favorites/coach_mark_service.dart

import 'package:shared_preferences/shared_preferences.dart';

/// Tracks whether the one-time swipe hint on the favourites list has run.
///
/// This replaced a four-screen `tutorial_coach_mark` tour (pull-to-refresh,
/// swipe actions, settings menu, then a search tip) that fired the moment a
/// user saved their first river. It blacked the screen out to 90%, chained
/// its panels one into the next, and was built with `hideSkip: true` — so
/// there was no way out of it except to tap through to the end. Three of its
/// four panels explained gestures people already know.
///
/// What survives is the one thing that genuinely is not discoverable: that
/// there are actions hidden behind a favourite card. It is now shown by
/// animating the card itself rather than by covering the screen.
class CoachMarkService {
  static const String _swipeHintKey = 'has_seen_swipe_hint';
  static const String _visitCountKey = 'favorites_visit_count';

  /// Show the hint on the user's SECOND arrival at the favourites list, not
  /// the first. The first visit is when someone has just saved a river and
  /// wants to look at it; interrupting that moment to teach a gesture is
  /// what made the old tour feel invasive.
  static const int showOnVisit = 2;

  static Future<bool> hasSeenSwipeHint() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_swipeHintKey) ?? false;
  }

  static Future<void> completeSwipeHint() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_swipeHintKey, true);
  }

  /// Count this arrival at the favourites list and return the new total.
  static Future<int> recordVisit() async {
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getInt(_visitCountKey) ?? 0) + 1;
    await prefs.setInt(_visitCountKey, next);
    return next;
  }

  static Future<int> visitCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_visitCountKey) ?? 0;
  }

  /// Whether this arrival should run the hint.
  ///
  /// [hasAnyFavourite] matters: the hint demonstrates a gesture ON a card, so
  /// with an empty list there is nothing to show and the visit should not
  /// burn the one chance to show it.
  static bool shouldShowOnVisit({
    required int visit,
    required bool alreadySeen,
    required bool hasAnyFavourite,
  }) {
    if (alreadySeen || !hasAnyFavourite) return false;
    return visit >= showOnVisit;
  }
}
