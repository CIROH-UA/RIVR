// lib/services/1_contracts/shared/i_forecast_service.dart

import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/hourly_flow_data.dart';
import 'package:rivr/models/1_domain/shared/forecast_chart_data.dart';

/// Data bundle returned by [IForecastService.loadReachDetailsData].
class ReachDetailsData {
  final String? riverName;
  final String? formattedLocation;
  final double? currentFlow;
  final String? flowCategory;
  final double? latitude;
  final double? longitude;
  final bool isClassificationAvailable;

  const ReachDetailsData({
    this.riverName,
    this.formattedLocation,
    this.currentFlow,
    this.flowCategory,
    this.latitude,
    this.longitude,
    this.isClassificationAvailable = false,
  });
}

/// Interface for forecast data loading and processing
abstract class IForecastService {
  Future<ForecastResponse> loadOverviewData(String reachId);
  Future<ForecastResponse> loadSupplementaryData(
    String reachId,
    ForecastResponse existingData,
  );
  Future<ForecastResponse> loadCompleteReachData(String reachId);
  Future<ForecastResponse> loadSpecificForecast(
    String reachId,
    String forecastType,
  );
  Future<ForecastResponse> refreshReachData(String reachId);
  Future<bool> isReachCached(String reachId);
  Future<Map<String, dynamic>> getCacheStats();
  Future<ForecastResponse> loadCurrentFlowOnly(String reachId);
  Future<ReachData> loadBasicReachInfo(String reachId);
  ForecastResponse mergeCurrentFlowData(
    ForecastResponse existing,
    ForecastResponse newFlowData,
  );
  double? getCurrentFlow(ForecastResponse forecast, {String? preferredType});
  String getFlowCategory(ForecastResponse forecast, {String? preferredType});
  List<String> getAvailableForecastTypes(ForecastResponse forecast);
  bool hasEnsembleData(ForecastResponse forecast);
  Map<String, dynamic> getEnsembleSummary(
    ForecastResponse forecast,
    String forecastType,
  );
  List<HourlyFlowDataPoint> getShortRangeHourlyData(ForecastResponse forecast);
  List<HourlyFlowDataPoint> getAllShortRangeHourlyData(
    ForecastResponse forecast,
  );
  List<EnsembleStatPoint> getEnsembleStatistics(
    ForecastResponse forecast,
    String forecastType,
  );
  bool hasMultipleEnsembleMembers(
    ForecastResponse forecast,
    String forecastType,
  );
  Map<String, List<ChartData>> getEnsembleSeriesForChart(
    ForecastResponse forecast,
    String forecastType,
  );
  List<ChartDataPoint> getEnsembleReferenceData(
    ForecastResponse forecast,
    String forecastType,
  );
  void clearUnitDependentCaches();
  void clearComputedCaches();

  /// Load all data needed for the reach details bottom sheet in one call.
  /// Returns overview data with return periods loaded (if available).
  Future<ReachDetailsData> loadReachDetailsData(String reachId);
}
