// lib/models/2_usecases/features/favorites/reorder_favorites_usecase.dart

import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';

class ReorderFavoritesUseCase {
  final IFavoritesRepository _repository;
  const ReorderFavoritesUseCase(this._repository);

  Future<ServiceResult<bool>> call(List<FavoriteRiver> reorderedFavorites) =>
      _repository.reorderFavorites(reorderedFavorites);
}
