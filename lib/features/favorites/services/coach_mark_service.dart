// lib/features/favorites/services/coach_mark_service.dart

import 'package:shared_preferences/shared_preferences.dart';

class CoachMarkService {
  static const String _favoritesTourKey = 'has_seen_favorites_tour';
  static const String _searchTipKey = 'has_seen_search_tip';

  static Future<bool> hasSeenFavoritesTour() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_favoritesTourKey) ?? false;
  }

  static Future<void> completeFavoritesTour() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_favoritesTourKey, true);
  }

  static Future<bool> hasSeenSearchTip() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_searchTipKey) ?? false;
  }

  static Future<void> completeSearchTip() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_searchTipKey, true);
  }
}
