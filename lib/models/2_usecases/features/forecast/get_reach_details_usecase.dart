// lib/models/2_usecases/features/forecast/get_reach_details_usecase.dart

import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_forecast_repository.dart';

class GetReachDetailsUseCase {
  final IForecastRepository _repository;
  const GetReachDetailsUseCase(this._repository);

  Future<ServiceResult<ReachDetailsData>> call(String reachId) =>
      _repository.getReachDetails(reachId);
}
