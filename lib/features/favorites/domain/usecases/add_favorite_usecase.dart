// lib/features/favorites/domain/usecases/add_favorite_usecase.dart

import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_favorites_repository.dart';

class AddFavoriteUseCase {
  final IFavoritesRepository _repository;
  const AddFavoriteUseCase(this._repository);

  Future<ServiceResult<bool>> call(String reachId, {String? customName}) =>
      _repository.addFavorite(reachId, customName: customName);
}
