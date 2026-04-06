// lib/features/favorites/domain/usecases/initialize_favorites_usecase.dart

import 'package:rivr/core/models/favorite_river.dart';
import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_favorites_repository.dart';

class InitializeFavoritesUseCase {
  final IFavoritesRepository _repository;
  const InitializeFavoritesUseCase(this._repository);

  Future<ServiceResult<List<FavoriteRiver>>> call() =>
      _repository.loadFavorites();
}
