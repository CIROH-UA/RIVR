// lib/models/2_usecases/features/favorites/remove_favorite_usecase.dart

import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';

class RemoveFavoriteUseCase {
  final IFavoritesRepository _repository;
  const RemoveFavoriteUseCase(this._repository);

  Future<ServiceResult<bool>> call(String reachId) =>
      _repository.removeFavorite(reachId);
}
