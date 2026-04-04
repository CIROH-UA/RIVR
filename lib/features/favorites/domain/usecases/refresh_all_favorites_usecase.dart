// lib/features/favorites/domain/usecases/refresh_all_favorites_usecase.dart

import 'package:rivr/core/models/favorite_river.dart';
import 'package:rivr/core/models/reach_data.dart';
import '../repositories/i_favorites_repository.dart';

/// Refreshes flow data for every reach in [favorites].
/// Returns a map of reachId → latest ForecastResponse (or null on error).
class RefreshAllFavoritesUseCase {
  final IFavoritesRepository _repository;
  const RefreshAllFavoritesUseCase(this._repository);

  Future<Map<String, ForecastResponse?>> call(List<FavoriteRiver> favorites) async {
    final results = <String, ForecastResponse?>{};
    await Future.wait(favorites.map((f) async {
      try {
        results[f.reachId] = await _repository.refreshFlowData(f.reachId);
      } catch (_) {
        results[f.reachId] = null;
      }
    }));
    return results;
  }
}
