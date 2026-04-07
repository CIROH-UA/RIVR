// lib/models/2_usecases/features/map/get_reach_details_for_map_usecase.dart

import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_forecast_repository.dart';

/// Loads the data needed for the map's reach-details bottom sheet.
/// Delegates to [IForecastRepository] so the map feature stays decoupled
/// from [IForecastService] page-scoped services.
class GetReachDetailsForMapUseCase {
  final IForecastRepository _repository;
  const GetReachDetailsForMapUseCase(this._repository);

  Future<ServiceResult<ReachDetailsData>> call(String reachId) =>
      _repository.getReachDetails(reachId);
}
