// lib/models/2_usecases/features/favorites/update_favorite_usecase.dart

import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';

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
