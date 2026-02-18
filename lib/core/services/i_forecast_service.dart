// lib/core/services/i_forecast_service.dart

import '../models/reach_data.dart';
import '../models/hourly_flow_data.dart';
import '../models/forecast_chart_data.dart';

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
}
