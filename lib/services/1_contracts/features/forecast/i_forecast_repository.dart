// lib/services/1_contracts/features/forecast/i_forecast_repository.dart

import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

/// Repository contract for forecast data operations.
abstract class IForecastRepository {
  Future<ServiceResult<ForecastResponse>> loadOverview(String reachId);
  Future<ServiceResult<ForecastResponse>> loadSupplementary(
    String reachId,
    ForecastResponse existingData,
  );
  Future<ServiceResult<ForecastResponse>> loadComplete(String reachId);
  Future<ServiceResult<ForecastResponse>> loadSpecificForecast(
    String reachId,
    String forecastType,
  );
  Future<ServiceResult<ForecastResponse>> refresh(String reachId);
  Future<ServiceResult<ReachDetailsData>> getReachDetails(String reachId);
}
