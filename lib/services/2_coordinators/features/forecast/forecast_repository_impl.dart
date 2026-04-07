// lib/services/2_coordinators/features/forecast/forecast_repository_impl.dart

import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_forecast_repository.dart';

/// Coordinator that wraps [IForecastService] operations with
/// [ServiceResult] error handling.
///
/// Catches exceptions thrown by the underlying service and maps them
/// to [ServiceException] failures so use cases return structured results
/// instead of throwing.
class ForecastRepositoryImpl implements IForecastRepository {
  final IForecastService _forecastService;

  const ForecastRepositoryImpl({required IForecastService forecastService})
      : _forecastService = forecastService;

  @override
  Future<ServiceResult<ForecastResponse>> loadOverview(String reachId) async {
    try {
      final result = await _forecastService.loadOverviewData(reachId);
      return ServiceResult.success(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'loadOverview'),
      );
    }
  }

  @override
  Future<ServiceResult<ForecastResponse>> loadSupplementary(
    String reachId,
    ForecastResponse existingData,
  ) async {
    try {
      final result = await _forecastService.loadSupplementaryData(
        reachId,
        existingData,
      );
      return ServiceResult.success(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'loadSupplementary'),
      );
    }
  }

  @override
  Future<ServiceResult<ForecastResponse>> loadComplete(String reachId) async {
    try {
      final result = await _forecastService.loadCompleteReachData(reachId);
      return ServiceResult.success(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'loadComplete'),
      );
    }
  }

  @override
  Future<ServiceResult<ForecastResponse>> loadSpecificForecast(
    String reachId,
    String forecastType,
  ) async {
    try {
      final result = await _forecastService.loadSpecificForecast(
        reachId,
        forecastType,
      );
      return ServiceResult.success(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'loadSpecificForecast'),
      );
    }
  }

  @override
  Future<ServiceResult<ForecastResponse>> refresh(String reachId) async {
    try {
      final result = await _forecastService.refreshReachData(reachId);
      return ServiceResult.success(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'refresh'),
      );
    }
  }

  @override
  Future<ServiceResult<ReachDetailsData>> getReachDetails(
    String reachId,
  ) async {
    try {
      final result = await _forecastService.loadReachDetailsData(reachId);
      return ServiceResult.success(result);
    } catch (e) {
      return ServiceResult.failure(
        ServiceException.fromError(e, context: 'getReachDetails'),
      );
    }
  }
}
