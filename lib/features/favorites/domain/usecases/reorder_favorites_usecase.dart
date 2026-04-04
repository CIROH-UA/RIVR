// lib/features/favorites/domain/usecases/reorder_favorites_usecase.dart

import 'package:rivr/core/models/favorite_river.dart';
import '../repositories/i_favorites_repository.dart';

class ReorderFavoritesUseCase {
  final IFavoritesRepository _repository;
  const ReorderFavoritesUseCase(this._repository);

  Future<bool> call(List<FavoriteRiver> reorderedFavorites) =>
      _repository.reorderFavorites(reorderedFavorites);
}
