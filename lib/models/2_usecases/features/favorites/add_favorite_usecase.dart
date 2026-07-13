// lib/models/2_usecases/features/favorites/add_favorite_usecase.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';

class AddFavoriteUseCase {
  final IFavoritesRepository _repository;
  const AddFavoriteUseCase(this._repository);

  Future<ServiceResult<bool>> call(
    String reachId, {
    String? customName,
    ForecastSource source = ForecastSource.nwm,
  }) =>
      _repository.addFavorite(reachId, customName: customName, source: source);
}
