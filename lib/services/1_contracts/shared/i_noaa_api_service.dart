// lib/services/1_contracts/shared/i_noaa_api_service.dart

/// Interface for NOAA API data fetching
abstract class INoaaApiService {
  Future<Map<String, dynamic>> fetchReachInfo(
    String reachId, {
    bool isOverview = false,
  });
  Future<Map<String, dynamic>> fetchCurrentFlowOnly(String reachId);
  Future<List<dynamic>> fetchReturnPeriods(String reachId);
  Future<Map<String, dynamic>> fetchForecast(
    String reachId,
    String series, {
    bool isOverview = false,
  });
  Future<Map<String, dynamic>> fetchOverviewData(String reachId);
  Future<Map<String, dynamic>> fetchAllForecasts(String reachId);
}
