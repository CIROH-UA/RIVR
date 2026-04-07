// lib/features/favorites/domain/usecases/get_favorite_flow_usecase.dart

import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';

class GetFavoriteFlowUseCase {
  final IFavoritesRepository _repository;
  const GetFavoriteFlowUseCase(this._repository);

  Future<ServiceResult<ForecastResponse>> call(String reachId) =>
      _repository.getFlowData(reachId);
}
