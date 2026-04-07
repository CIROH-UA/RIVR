// lib/services/1_contracts/shared/i_favorites_service.dart

import 'package:rivr/models/1_domain/shared/favorite_river.dart';

/// Interface for managing user's favorite rivers
abstract class IFavoritesService {
  Future<List<FavoriteRiver>> loadFavorites();
  Future<bool> saveFavorites(List<FavoriteRiver> favorites);
  Future<bool> addFavorite(
    String reachId, {
    String? customName,
    double? latitude,
    double? longitude,
  });
  Future<bool> removeFavorite(String reachId);
  Future<bool> isFavorite(String reachId);
  Future<bool> reorderFavorites(List<FavoriteRiver> reorderedFavorites);
  Future<bool> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
    double? lastKnownFlow,
    DateTime? lastUpdated,
    double? latitude,
    double? longitude,
  });
  Future<int> getFavoritesCount();
  Future<bool> clearAllFavorites();
}
