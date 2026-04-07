// lib/ui/1_state/features/forecast/reach_data_cache_mixin.dart

import 'package:flutter/foundation.dart';
import 'package:rivr/models/1_domain/shared/hourly_flow_data.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';

/// Extracted computed-value caching logic for ReachDataProvider.
/// Owns session cache, computed caches, cached getters, and cache management.
mixin ReachDataCacheMixin on ChangeNotifier {
  // Abstract — provided by the host class
  IForecastService get forecastService;
  ForecastResponse? get currentForecast;

  // Simple in-memory cache for current session
  final Map<String, ForecastResponse> sessionCache = {};

  // Computed value caches (avoid repeated calculations)
  final Map<String, double?> _currentFlowCache = {};
  final Map<String, String> _flowCategoryCache = {};
  final Map<String, String> _formattedLocationCache = {};
  final Map<String, List<String>> _availableForecastTypesCache = {};

  // --- Cached getters ---

  /// Get current flow value for display — cached
  double? getCurrentFlow({String? preferredType}) {
    if (currentForecast == null) return null;

    final reachId = currentForecast!.reach.reachId;
    final cacheKey = '$reachId-${preferredType ?? 'default'}';

    if (_currentFlowCache.containsKey(cacheKey)) {
      return _currentFlowCache[cacheKey];
    }

    final flow = forecastService.getCurrentFlow(
      currentForecast!,
      preferredType: preferredType,
    );

    _currentFlowCache[cacheKey] = flow;
    return flow;
  }

  /// Get flow category — cached
  String getFlowCategory({String? preferredType}) {
    if (currentForecast == null) return 'Unknown';

    final reachId = currentForecast!.reach.reachId;
    final cacheKey = '$reachId-${preferredType ?? 'default'}';

    if (_flowCategoryCache.containsKey(cacheKey)) {
      return _flowCategoryCache[cacheKey]!;
    }

    final category = forecastService.getFlowCategory(
      currentForecast!,
      preferredType: preferredType,
    );
    _flowCategoryCache[cacheKey] = category;
    return category;
  }

  /// Get formatted location for display — cached
  String getFormattedLocation() {
    if (currentForecast == null) return '';

    final reachId = currentForecast!.reach.reachId;

    if (_formattedLocationCache.containsKey(reachId)) {
      return _formattedLocationCache[reachId]!;
    }

    final location = currentForecast!.reach.formattedLocationSubtitle;
    _formattedLocationCache[reachId] = location;
    return location;
  }

  /// Get available forecast types — cached
  List<String> getAvailableForecastTypes() {
    if (currentForecast == null) return [];

    final reachId = currentForecast!.reach.reachId;

    if (_availableForecastTypesCache.containsKey(reachId)) {
      return _availableForecastTypesCache[reachId]!;
    }

    final types = forecastService.getAvailableForecastTypes(currentForecast!);
    _availableForecastTypesCache[reachId] = types;
    return types;
  }

  /// Check if current reach has ensemble data
  bool hasEnsembleData() {
    if (currentForecast == null) return false;
    return forecastService.hasEnsembleData(currentForecast!);
  }

  /// Get hourly data for short-range forecast with calculated trends
  List<HourlyFlowDataPoint> getShortRangeHourlyData() {
    if (currentForecast == null) return [];
    return forecastService.getShortRangeHourlyData(currentForecast!);
  }

  /// Get ALL hourly data for charts (including past hours)
  List<HourlyFlowDataPoint> getAllShortRangeHourlyData() {
    if (currentForecast == null) return [];
    return forecastService.getAllShortRangeHourlyData(currentForecast!);
  }

  // --- Cache management ---

  /// Pre-compute commonly used values when data changes
  void updateComputedCaches(String reachId) {
    if (currentForecast == null) return;

    getCurrentFlow();
    getFlowCategory();
    getFormattedLocation();
    getAvailableForecastTypes();
  }

  /// Clear computed caches for a specific reach
  void clearComputedCachesForReach(String reachId) {
    _currentFlowCache.removeWhere((key, value) => key.startsWith(reachId));
    _flowCategoryCache.removeWhere((key, value) => key.startsWith(reachId));
    _formattedLocationCache.remove(reachId);
    _availableForecastTypesCache.remove(reachId);
  }

  /// Clear only flow-related caches for a reach so current flow gets
  /// recalculated after a new section merges in (Phase 4 parallel loading).
  void clearFlowCachesForReach(String reachId) {
    _currentFlowCache.removeWhere((key, _) => key.startsWith(reachId));
    _flowCategoryCache.removeWhere((key, _) => key.startsWith(reachId));
    _availableForecastTypesCache.remove(reachId);
  }

  /// Clear all computed caches
  void clearAllComputedCaches() {
    _currentFlowCache.clear();
    _flowCategoryCache.clear();
    _formattedLocationCache.clear();
    _availableForecastTypesCache.clear();
  }

  /// Clear unit-dependent cached values (call when unit preference changes)
  void clearUnitDependentCaches() {
    _currentFlowCache.clear();
    _flowCategoryCache.clear();

    // Also clear session cache since it may contain unconverted data
    sessionCache.clear();

    // Also clear ForecastService unit-dependent caches
    forecastService.clearUnitDependentCaches();

    // Trigger UI update to refresh displayed values
    notifyListeners();
  }

  /// Get cache statistics for debugging
  Future<Map<String, dynamic>> getCacheStats() async {
    final diskStats = await forecastService.getCacheStats();
    return {
      'sessionCached': sessionCache.length,
      'sessionReaches': sessionCache.keys.toList(),
      'diskCache': diskStats,
      'computedCaches': {
        'currentFlow': _currentFlowCache.length,
        'flowCategory': _flowCategoryCache.length,
        'formattedLocation': _formattedLocationCache.length,
        'availableForecastTypes': _availableForecastTypesCache.length,
      },
    };
  }
}
