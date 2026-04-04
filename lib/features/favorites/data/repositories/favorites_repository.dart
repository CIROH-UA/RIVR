// lib/features/favorites/data/repositories/favorites_repository.dart

import 'package:rivr/core/models/favorite_river.dart';
import 'package:rivr/core/models/reach_data.dart';
import 'package:rivr/core/services/i_favorites_service.dart';
import 'package:rivr/core/services/i_forecast_service.dart';
import 'package:rivr/core/services/i_reach_cache_service.dart';
import 'package:rivr/core/services/i_flow_unit_preference_service.dart';
import 'package:rivr/core/services/i_noaa_api_service.dart';
import '../../domain/repositories/i_favorites_repository.dart';

/// Aggregates five data sources to satisfy [IFavoritesRepository]:
/// IFavoritesService, IForecastService, IReachCacheService,
/// IFlowUnitPreferenceService, and INoaaApiService.
class FavoritesRepository implements IFavoritesRepository {
  final IFavoritesService _favoritesService;
  final IForecastService _forecastService;
  final IReachCacheService _cacheService;
  final IFlowUnitPreferenceService _unitService;
  final INoaaApiService _apiService;

  const FavoritesRepository({
    required IFavoritesService favoritesService,
    required IForecastService forecastService,
    required IReachCacheService cacheService,
    required IFlowUnitPreferenceService unitService,
    required INoaaApiService apiService,
  })  : _favoritesService = favoritesService,
        _forecastService = forecastService,
        _cacheService = cacheService,
        _unitService = unitService,
        _apiService = apiService;

  @override
  Future<List<FavoriteRiver>> loadFavorites() => _favoritesService.loadFavorites();

  @override
  Future<bool> addFavorite(String reachId, {String? customName}) =>
      _favoritesService.addFavorite(reachId, customName: customName);

  @override
  Future<bool> removeFavorite(String reachId) =>
      _favoritesService.removeFavorite(reachId);

  @override
  Future<bool> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
  }) =>
      _favoritesService.updateFavorite(
        reachId,
        customName: customName,
        riverName: riverName,
        customImageAsset: customImageAsset,
      );

  @override
  Future<bool> reorderFavorites(List<FavoriteRiver> reorderedFavorites) =>
      _favoritesService.reorderFavorites(reorderedFavorites);

  /// Loads current flow data; falls back to cached return periods when
  /// the forecast response doesn't include them.
  @override
  Future<ForecastResponse> getFlowData(String reachId) async {
    final forecast = await _forecastService.loadCurrentFlowOnly(reachId);

    // If return periods already present in forecast, we're done
    if (forecast.reach.hasReturnPeriods) return forecast;

    // Check cache for return periods
    final cached = await _cacheService.get(reachId);
    if (cached?.hasReturnPeriods == true) {
      final merged = forecast.reach.mergeWith(cached!);
      return ForecastResponse(
        reach: merged,
        analysisAssimilation: forecast.analysisAssimilation,
        shortRange: forecast.shortRange,
        mediumRange: forecast.mediumRange,
        longRange: forecast.longRange,
        mediumRangeBlend: forecast.mediumRangeBlend,
      );
    }

    // Fetch return periods fresh and cache them
    final returnPeriods = await _apiService.fetchReturnPeriods(reachId);
    if (returnPeriods.isNotEmpty) {
      final returnPeriodData = ReachData.fromReturnPeriodApi(returnPeriods);
      if (cached != null) {
        await _cacheService.store(cached.mergeWith(returnPeriodData));
      }
      final merged = forecast.reach.mergeWith(returnPeriodData);
      return ForecastResponse(
        reach: merged,
        analysisAssimilation: forecast.analysisAssimilation,
        shortRange: forecast.shortRange,
        mediumRange: forecast.mediumRange,
        longRange: forecast.longRange,
        mediumRangeBlend: forecast.mediumRangeBlend,
      );
    }

    return forecast;
  }

  @override
  Future<ForecastResponse> refreshFlowData(String reachId) =>
      _forecastService.refreshReachData(reachId);
}

// Expose unit service for providers that still need it directly
// (kept for DI completeness — not a repository method)
extension FavoritesRepositoryExt on FavoritesRepository {
  IFlowUnitPreferenceService get unitService => _unitService;
}
