// lib/features/favorites/domain/repositories/i_favorites_repository.dart

import 'package:rivr/core/models/favorite_river.dart';
import 'package:rivr/core/models/reach_data.dart';

/// Repository contract for favorites operations.
/// Aggregates IFavoritesService, IForecastService, IReachCacheService,
/// IFlowUnitPreferenceService, and INoaaApiService.
abstract class IFavoritesRepository {
  Future<List<FavoriteRiver>> loadFavorites();
  Future<bool> addFavorite(String reachId, {String? customName});
  Future<bool> removeFavorite(String reachId);
  Future<bool> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
  });
  Future<bool> reorderFavorites(List<FavoriteRiver> reorderedFavorites);

  /// Load current flow + return period data for a single favorite.
  Future<ForecastResponse> getFlowData(String reachId);

  /// Force-refresh flow data for a single favorite (bypasses caches).
  Future<ForecastResponse> refreshFlowData(String reachId);
}
