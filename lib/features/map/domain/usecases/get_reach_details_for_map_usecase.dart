// lib/features/map/domain/usecases/get_reach_details_for_map_usecase.dart

import 'package:rivr/core/services/i_forecast_service.dart';
import 'package:rivr/features/forecast/domain/repositories/i_forecast_repository.dart';

/// Loads the data needed for the map's reach-details bottom sheet.
/// Delegates to [IForecastRepository] so the map feature stays decoupled
/// from [IForecastService] page-scoped services.
class GetReachDetailsForMapUseCase {
  final IForecastRepository _repository;
  const GetReachDetailsForMapUseCase(this._repository);

  Future<ReachDetailsData> call(String reachId) =>
      _repository.getReachDetails(reachId);
}
