// lib/services/2_coordinators/features/favorites/favorites_repository_impl.dart

import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/services/3_datasources/shared/dtos/reach_data_dto.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';

/// Coordinator that wraps favorites operations with [ServiceResult] error
/// handling. Aggregates five data sources: [IFavoritesService],
/// [IForecastService], [IReachCacheService], [IFlowUnitPreferenceService],
/// and [INoaaApiService].
class FavoritesRepositoryImpl implements IFavoritesRepository {
  final IFavoritesService _favoritesService;
  final IForecastService _forecastService;
  final IReachCacheService _cacheService;
  final IFlowUnitPreferenceService _unitService;
  final INoaaApiService _apiService;

  const FavoritesRepositoryImpl({
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
  Future<ServiceResult<List<FavoriteRiver>>> loadFavorites() async {
    try {
      final favorites = await _favoritesService.loadFavorites();
      return ServiceResult.success(favorites);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'loadFavorites'),
      );
    }
  }

  @override
  Future<ServiceResult<bool>> addFavorite(
    String reachId, {
    String? customName,
  }) async {
    try {
      final success = await _favoritesService.addFavorite(
        reachId,
        customName: customName,
      );
      return ServiceResult.success(success);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'addFavorite'),
      );
    }
  }

  @override
  Future<ServiceResult<bool>> removeFavorite(String reachId) async {
    try {
      final success = await _favoritesService.removeFavorite(reachId);
      return ServiceResult.success(success);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'removeFavorite'),
      );
    }
  }

  @override
  Future<ServiceResult<bool>> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
  }) async {
    try {
      final success = await _favoritesService.updateFavorite(
        reachId,
        customName: customName,
        riverName: riverName,
        customImageAsset: customImageAsset,
      );
      return ServiceResult.success(success);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'updateFavorite'),
      );
    }
  }

  @override
  Future<ServiceResult<bool>> reorderFavorites(
    List<FavoriteRiver> reorderedFavorites,
  ) async {
    try {
      final success =
          await _favoritesService.reorderFavorites(reorderedFavorites);
      return ServiceResult.success(success);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'reorderFavorites'),
      );
    }
  }

  /// Loads current flow data; falls back to cached return periods when
  /// the forecast response doesn't include them.
  @override
  Future<ServiceResult<ForecastResponse>> getFlowData(String reachId) async {
    try {
      final forecast = await _forecastService.loadCurrentFlowOnly(reachId);

      // If return periods already present in forecast, we're done
      if (forecast.reach.hasReturnPeriods) {
        return ServiceResult.success(forecast);
      }

      // Check cache for return periods
      final cached = await _cacheService.get(reachId);
      if (cached?.hasReturnPeriods == true) {
        final merged = forecast.reach.mergeWith(cached!);
        return ServiceResult.success(ForecastResponse(
          reach: merged,
          analysisAssimilation: forecast.analysisAssimilation,
          shortRange: forecast.shortRange,
          mediumRange: forecast.mediumRange,
          longRange: forecast.longRange,
          mediumRangeBlend: forecast.mediumRangeBlend,
        ));
      }

      // Fetch return periods fresh and cache them
      final returnPeriods = await _apiService.fetchReturnPeriods(reachId);
      if (returnPeriods.isNotEmpty) {
        final returnPeriodData =
            ReachDataDto.fromReturnPeriodApi(returnPeriods).toEntity();
        if (cached != null) {
          await _cacheService.store(cached.mergeWith(returnPeriodData));
        }
        final merged = forecast.reach.mergeWith(returnPeriodData);
        return ServiceResult.success(ForecastResponse(
          reach: merged,
          analysisAssimilation: forecast.analysisAssimilation,
          shortRange: forecast.shortRange,
          mediumRange: forecast.mediumRange,
          longRange: forecast.longRange,
          mediumRangeBlend: forecast.mediumRangeBlend,
        ));
      }

      return ServiceResult.success(forecast);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'getFlowData'),
      );
    }
  }

  @override
  Future<ServiceResult<ForecastResponse>> refreshFlowData(
    String reachId,
  ) async {
    try {
      final forecast = await _forecastService.refreshReachData(reachId);
      return ServiceResult.success(forecast);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'refreshFlowData'),
      );
    }
  }
}

// Expose unit service for providers that still need it directly
// (kept for DI completeness — not a repository method)
extension FavoritesRepositoryImplExt on FavoritesRepositoryImpl {
  IFlowUnitPreferenceService get unitService => _unitService;
}
