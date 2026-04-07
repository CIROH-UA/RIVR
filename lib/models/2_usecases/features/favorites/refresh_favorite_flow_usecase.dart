// lib/models/2_usecases/features/favorites/refresh_favorite_flow_usecase.dart

import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';

class RefreshFavoriteFlowUseCase {
  final IFavoritesRepository _repository;
  const RefreshFavoriteFlowUseCase(this._repository);

  Future<ServiceResult<ForecastResponse>> call(String reachId) =>
      _repository.refreshFlowData(reachId);
}
