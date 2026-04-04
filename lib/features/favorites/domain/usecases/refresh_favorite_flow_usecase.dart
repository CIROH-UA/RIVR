// lib/features/favorites/domain/usecases/refresh_favorite_flow_usecase.dart

import 'package:rivr/core/models/reach_data.dart';
import '../repositories/i_favorites_repository.dart';

class RefreshFavoriteFlowUseCase {
  final IFavoritesRepository _repository;
  const RefreshFavoriteFlowUseCase(this._repository);

  Future<ForecastResponse> call(String reachId) => _repository.refreshFlowData(reachId);
}
