// lib/services/1_contracts/features/favorites/i_favorites_repository.dart

import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

/// Repository contract for favorites operations.
/// Aggregates IFavoritesService, IForecastService, IReachCacheService,
/// IFlowUnitPreferenceService, and INoaaApiService.
abstract class IFavoritesRepository {
  Future<ServiceResult<List<FavoriteRiver>>> loadFavorites();
  Future<ServiceResult<bool>> addFavorite(String reachId, {String? customName});
  Future<ServiceResult<bool>> removeFavorite(String reachId);
  Future<ServiceResult<bool>> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
  });
  Future<ServiceResult<bool>> reorderFavorites(
    List<FavoriteRiver> reorderedFavorites,
  );

  /// Load current flow + return period data for a single favorite.
  Future<ServiceResult<ForecastResponse>> getFlowData(String reachId);

  /// Force-refresh flow data for a single favorite (bypasses caches).
  Future<ServiceResult<ForecastResponse>> refreshFlowData(String reachId);
}
