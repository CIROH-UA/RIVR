// lib/services/2_coordinators/features/favorites/favorites_repository_impl.dart

import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';

/// Coordinator that wraps favorites operations with [ServiceResult] error
/// handling. Wraps [IFavoritesService] with [IFlowUnitPreferenceService] for
/// unit-tagged persistence — the flow-data paths that once aggregated three
/// more services were deleted in ADR 0011 Phase 3 (dormant behind a use case
/// nothing resolved).
class FavoritesRepositoryImpl implements IFavoritesRepository {
  final IFavoritesService _favoritesService;
  final IFlowUnitPreferenceService _unitService;

  const FavoritesRepositoryImpl({
    required IFavoritesService favoritesService,
    required IFlowUnitPreferenceService unitService,
  })  : _favoritesService = favoritesService,
        _unitService = unitService;

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
    ForecastSource source = ForecastSource.nwm,
  }) async {
    try {
      final success = await _favoritesService.addFavorite(
        reachId,
        customName: customName,
        source: source,
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

  }

// Expose unit service for providers that still need it directly
// (kept for DI completeness — not a repository method)
extension FavoritesRepositoryImplExt on FavoritesRepositoryImpl {
  IFlowUnitPreferenceService get unitService => _unitService;
}
