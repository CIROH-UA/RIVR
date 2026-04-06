// lib/features/favorites/domain/usecases/update_favorite_usecase.dart

import 'package:rivr/core/services/service_result.dart';
import '../repositories/i_favorites_repository.dart';

class UpdateFavoriteUseCase {
  final IFavoritesRepository _repository;
  const UpdateFavoriteUseCase(this._repository);

  Future<ServiceResult<bool>> call(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
  }) =>
      _repository.updateFavorite(
        reachId,
        customName: customName,
        riverName: riverName,
        customImageAsset: customImageAsset,
      );
}
