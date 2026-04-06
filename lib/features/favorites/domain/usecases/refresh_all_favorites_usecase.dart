// lib/features/favorites/domain/usecases/refresh_all_favorites_usecase.dart

import 'package:rivr/core/models/favorite_river.dart';
import 'package:rivr/core/models/reach_data.dart';
import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_favorites_repository.dart';

/// Refreshes flow data for every reach in [favorites].
/// Returns a map of reachId → latest ForecastResponse (or null on error).
class RefreshAllFavoritesUseCase {
  final IFavoritesRepository _repository;
  const RefreshAllFavoritesUseCase(this._repository);

  Future<ServiceResult<Map<String, ForecastResponse?>>> call(
    List<FavoriteRiver> favorites,
  ) async {
    try {
      final results = <String, ForecastResponse?>{};
      await Future.wait(favorites.map((f) async {
        final result = await _repository.refreshFlowData(f.reachId);
        results[f.reachId] = result.isSuccess ? result.data : null;
      }));
      return ServiceResult.success(results);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'refreshAllFavorites'),
      );
    }
  }
}
