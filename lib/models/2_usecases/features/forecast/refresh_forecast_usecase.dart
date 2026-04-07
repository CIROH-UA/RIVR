// lib/models/2_usecases/features/forecast/refresh_forecast_usecase.dart

import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_forecast_repository.dart';

class RefreshForecastUseCase {
  final IForecastRepository _repository;
  const RefreshForecastUseCase(this._repository);

  Future<ServiceResult<ForecastResponse>> call(String reachId) =>
      _repository.refresh(reachId);
}
