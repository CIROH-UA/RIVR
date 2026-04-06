// lib/features/favorites/domain/usecases/remove_favorite_usecase.dart

import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_favorites_repository.dart';

class RemoveFavoriteUseCase {
  final IFavoritesRepository _repository;
  const RemoveFavoriteUseCase(this._repository);

  Future<ServiceResult<bool>> call(String reachId) =>
      _repository.removeFavorite(reachId);
}
