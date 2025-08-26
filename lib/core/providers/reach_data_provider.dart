// lib/core/providers/reach_data_provider.dart

import 'package:flutter/foundation.dart';
import 'package:rivrflow/features/forecast/widgets/horizontal_flow_timeline.dart';
import '../models/reach_data.dart';
import '../services/forecast_service.dart';

/// State management for reach and forecast data
/// Now with phased loading and progressive forecast category loading
class ReachDataProvider with ChangeNotifier {
  final ForecastService _forecastService = ForecastService();

  // Current state
  bool _isLoading = false;
  String? _errorMessage;
  ForecastResponse? _currentForecast;

  // Phased loading states
  bool _isLoadingOverview = false;
  bool _isLoadingSupplementary = false;
  String _loadingPhase =
      'none'; // 'none', 'overview', 'supplementary', 'complete'

  // Progressive forecast category loading states
  bool _isLoadingHourly = false;
  bool _isLoadingDaily = false;
  bool _isLoadingExtended = false;

  // Simple in-memory cache for current session
  final Map<String, ForecastResponse> _sessionCache = {};

  // Computed value caches (avoid repeated calculations)
  final Map<String, double?> _currentFlowCache = {};
  final Map<String, String> _flowCategoryCache = {};
  final Map<String, String> _formattedLocationCache = {};
  final Map<String, List<String>> _availableForecastTypesCache = {};

  // Getters
  bool get isLoading => _isLoading;
  bool get isLoadingOverview => _isLoadingOverview;
  bool get isLoadingSupplementary => _isLoadingSupplementary;
  String get loadingPhase => _loadingPhase;
  String? get errorMessage => _errorMessage;
  ForecastResponse? get currentForecast => _currentForecast;
  bool get hasData => _currentForecast != null;

  // Forecast category loading state getters
  bool get isLoadingHourly => _isLoadingHourly;
  bool get isLoadingDaily => _isLoadingDaily;
  bool get isLoadingExtended => _isLoadingExtended;

  // Get current reach data if available
  ReachData? get currentReach => _currentForecast?.reach;

  // Check if we have basic overview data
  bool get hasOverviewData =>
      _currentForecast != null && _currentForecast!.reach.hasLocationData;

  // Check if we have supplementary data (return periods)
  bool get hasSupplementaryData =>
      _currentForecast?.reach.hasReturnPeriods ?? false;

  // Check if specific forecast categories are available in current data
  bool get hasHourlyForecast =>
      _currentForecast?.shortRange?.isNotEmpty ?? false;
  bool get hasDailyForecast =>
      _currentForecast?.mediumRange.isNotEmpty ?? false;
  bool get hasExtendedForecast =>
      _currentForecast?.longRange.isNotEmpty ?? false;

  // Immediately clear current reach display (fixes wrong river issue)
  void clearCurrentReach() {
    _currentForecast = null;
    _clearAllComputedCaches();
    _clearError();
    _setLoadingPhase('none');
    _resetAllLoadingStates();
    notifyListeners();
  }

  // Get loading state summary for forecast categories
  Map<String, dynamic> getForecastCategoryLoadingState() {
    return {
      'hourly': {
        'loading': _isLoadingHourly,
        'available': hasHourlyForecast,
        'type': 'short_range',
      },
      'daily': {
        'loading': _isLoadingDaily,
        'available': hasDailyForecast,
        'type': 'medium_range',
      },
      'extended': {
        'loading': _isLoadingExtended,
        'available': hasExtendedForecast,
        'type': 'long_range',
      },
    };
  }

  // PHASE 1 - Load overview data only (reach info + current flow)
  /// Load minimal data for overview page display
  /// This is the fastest possible load - shows name, location, current flow immediately
  Future<bool> loadOverviewData(String reachId) async {
    _setLoadingOverview(true);
    _setLoadingPhase('overview');
    _clearError();

    try {
      // Check session cache first
      if (_sessionCache.containsKey(reachId)) {
        print('REACH_PROVIDER: Using cached data for overview: $reachId');
        _currentForecast = _sessionCache[reachId];
        _updateComputedCaches(reachId);
        _setLoadingOverview(false);
        _setLoadingPhase('complete'); // If cached, we have complete data
        return true;
      }

      // Load overview data from service (fast)
      final forecast = await _forecastService.loadOverviewData(reachId);

      _currentForecast = forecast;
      _updateComputedCaches(reachId);

      _setLoadingOverview(false);
      _setLoadingPhase('overview');
      return true;
    } catch (e) {
      print('REACH_PROVIDER: ❌ Error loading overview data: $e');
      _setError(e.toString());
      _setLoadingOverview(false);
      _setLoadingPhase('none');
      return false;
    }
  }

  // Load hourly forecast data specifically (short-range)
  Future<bool> loadHourlyForecast(String reachId) async {
    _setLoadingHourly(true);

    try {
      // If we don't have any data yet, load overview first
      if (_currentForecast == null) {
        final overviewSuccess = await loadOverviewData(reachId);
        if (!overviewSuccess) {
          _setLoadingHourly(false);
          return false;
        }
      }

      // Load hourly data
      final hourlyForecast = await _forecastService.loadSpecificForecast(
        reachId,
        'short_range',
      );

      // Merge with existing data instead of overwriting
      _currentForecast = _mergeForecastData(_currentForecast!, hourlyForecast);
      _sessionCache[reachId] = _currentForecast!;
      _updateComputedCaches(reachId);

      _setLoadingHourly(false);
      return true;
    } catch (e) {
      print('REACH_PROVIDER: ❌ Error loading hourly forecast: $e');
      _setLoadingHourly(false);
      return false;
    }
  }

  // Load daily forecast data specifically (medium-range)
  Future<bool> loadDailyForecast(String reachId) async {
    _setLoadingDaily(true);

    try {
      // If we don't have any data yet, load overview first
      if (_currentForecast == null) {
        final overviewSuccess = await loadOverviewData(reachId);
        if (!overviewSuccess) {
          _setLoadingDaily(false);
          return false;
        }
      }

      // Load daily data
      final dailyForecast = await _forecastService.loadSpecificForecast(
        reachId,
        'medium_range',
      );

      // Merge with existing data instead of overwriting
      _currentForecast = _mergeForecastData(_currentForecast!, dailyForecast);
      _sessionCache[reachId] = _currentForecast!;
      _updateComputedCaches(reachId);

      _setLoadingDaily(false);
      return true;
    } catch (e) {
      print('REACH_PROVIDER: ❌ Error loading daily forecast: $e');
      _setLoadingDaily(false);
      return false;
    }
  }

  // Load extended forecast data specifically (long-range)
  Future<bool> loadExtendedForecast(String reachId) async {
    _setLoadingExtended(true);

    try {
      // If we don't have any data yet, load overview first
      if (_currentForecast == null) {
        final overviewSuccess = await loadOverviewData(reachId);
        if (!overviewSuccess) {
          _setLoadingExtended(false);
          return false;
        }
      }

      // Load extended data
      final extendedForecast = await _forecastService.loadSpecificForecast(
        reachId,
        'long_range',
      );

      // Merge with existing data instead of overwriting
      _currentForecast = _mergeForecastData(
        _currentForecast!,
        extendedForecast,
      );
      _sessionCache[reachId] = _currentForecast!;
      _updateComputedCaches(reachId);

      _setLoadingExtended(false);
      return true;
    } catch (e) {
      print('REACH_PROVIDER: ❌ Error loading extended forecast: $e');
      _setLoadingExtended(false);
      return false;
    }
  }

  // Merge forecast data properly (preserves existing data)
  ForecastResponse _mergeForecastData(
    ForecastResponse existing,
    ForecastResponse newData,
  ) {
    return ForecastResponse(
      reach: existing.reach, // Keep existing reach data
      // Merge forecast data - use new data if available, otherwise keep existing
      analysisAssimilation: newData.analysisAssimilation?.isNotEmpty == true
          ? newData.analysisAssimilation
          : existing.analysisAssimilation,
      shortRange: newData.shortRange?.isNotEmpty == true
          ? newData.shortRange
          : existing.shortRange,
      mediumRange: newData.mediumRange.isNotEmpty
          ? newData.mediumRange
          : existing.mediumRange,
      longRange: newData.longRange.isNotEmpty
          ? newData.longRange
          : existing.longRange,
      mediumRangeBlend: newData.mediumRangeBlend?.isNotEmpty == true
          ? newData.mediumRangeBlend
          : existing.mediumRangeBlend,
    );
  }

  // Comprehensive refresh - loads all forecast categories systematically
  Future<bool> comprehensiveRefresh(String reachId) async {
    // Clear caches first
    _sessionCache.remove(reachId);
    _clearComputedCaches(reachId);
    _forecastService.clearComputedCaches();

    try {
      // Step 1: Load overview data first
      final overviewSuccess = await loadOverviewData(reachId);
      if (!overviewSuccess) {
        return false;
      }

      // Step 2: Load all forecast categories progressively
      // Note: These run sequentially so each one can enhance the previous data
      await loadHourlyForecast(reachId);
      await loadDailyForecast(reachId);
      await loadExtendedForecast(reachId);

      // Step 3: Load supplementary data
      await loadSupplementaryData(reachId);

      return true;
    } catch (e) {
      print('REACH_PROVIDER: ❌ Error in comprehensive refresh: $e');
      _setError(e.toString());
      return false;
    }
  }

  // PHASE 2 - Add supplementary data (return periods + forecast summaries)
  /// Enhance existing overview data with return periods and forecast summaries
  /// Call this after overview data is displayed to add functionality progressively
  Future<bool> loadSupplementaryData(String reachId) async {
    if (_currentForecast == null) {
      final success = await loadOverviewData(reachId);
      if (!success) return false;
    }

    _setLoadingSupplementary(true);
    _clearError();

    try {
      // Enhance existing data with supplementary information
      final enhancedForecast = await _forecastService.loadSupplementaryData(
        reachId,
        _currentForecast!,
      );

      _currentForecast = enhancedForecast;
      _sessionCache[reachId] = enhancedForecast; // Update cache

      // Update computed caches
      _updateComputedCaches(reachId);

      _setLoadingSupplementary(false);
      _setLoadingPhase('complete');
      return true;
    } catch (e) {
      // Don't set error - supplementary data is not critical
      // Keep existing overview data
      _setLoadingSupplementary(false);
      _setLoadingPhase('overview'); // Still have overview data
      return false; // Indicate supplementary loading failed, but don't break UI
    }
  }

  // Keep for backwards compatibility and complete loading
  /// Load complete reach and forecast data
  Future<bool> loadReach(String reachId) async {
    _setLoading(true);
    _setLoadingPhase('complete');
    _clearError();

    try {
      // Check session cache first
      if (_sessionCache.containsKey(reachId)) {
        _currentForecast = _sessionCache[reachId];
        _updateComputedCaches(reachId);
        _setLoading(false);
        _setLoadingPhase('complete');
        return true;
      }

      // Load from service (uses disk cache automatically)
      final forecast = await _forecastService.loadCompleteReachData(reachId);

      _currentForecast = forecast;
      _sessionCache[reachId] = forecast; // Cache for session
      _updateComputedCaches(reachId);

      _setLoading(false);
      _setLoadingPhase('complete');
      return true;
    } catch (e) {
      print('REACH_PROVIDER: ❌ Error loading complete data: $e');
      _setError(e.toString());
      _setLoading(false);
      _setLoadingPhase('none');
      return false;
    }
  }

  /// Load specific forecast type only (faster)
  Future<bool> loadSpecificForecast(String reachId, String forecastType) async {
    _setLoading(true);
    _clearError();

    try {
      final forecast = await _forecastService.loadSpecificForecast(
        reachId,
        forecastType,
      );

      _currentForecast = forecast;
      _sessionCache[reachId] = forecast;
      _updateComputedCaches(reachId);

      _setLoading(false);
      _setLoadingPhase('specific');
      return true;
    } catch (e) {
      _setError(e.toString());
      _setLoading(false);
      _setLoadingPhase('none');
      return false;
    }
  }

  /// Force refresh current reach (bypass all caches)
  Future<bool> refreshCurrentReach() async {
    if (_currentForecast == null) return false;

    final reachId = _currentForecast!.reach.reachId;

    // Use comprehensive refresh instead of basic loadReach
    return await comprehensiveRefresh(reachId);
  }

  // Use cached values instead of computing each time
  /// Get current flow value for display - now with caching
  double? getCurrentFlow({String? preferredType}) {
    if (_currentForecast == null) return null;

    final reachId = _currentForecast!.reach.reachId;
    final cacheKey = '$reachId-${preferredType ?? 'default'}';

    // Return cached value if available
    if (_currentFlowCache.containsKey(cacheKey)) {
      final cachedValue = _currentFlowCache[cacheKey];
      return cachedValue;
    }

    // Compute and cache
    final flow = _forecastService.getCurrentFlow(
      _currentForecast!,
      preferredType: preferredType,
    );

    _currentFlowCache[cacheKey] = flow;
    return flow;
  }

  // Use cached values instead of computing each time
  /// Get flow category - now with caching
  String getFlowCategory({String? preferredType}) {
    if (_currentForecast == null) return 'Unknown';

    final reachId = _currentForecast!.reach.reachId;
    final cacheKey = '$reachId-${preferredType ?? 'default'}';

    // Return cached value if available
    if (_flowCategoryCache.containsKey(cacheKey)) {
      return _flowCategoryCache[cacheKey]!;
    }

    // Compute and cache
    final category = _forecastService.getFlowCategory(
      _currentForecast!,
      preferredType: preferredType,
    );
    _flowCategoryCache[cacheKey] = category;
    return category;
  }

  // Cached formatted location (fixes subtitle issue)
  /// Get formatted location for display - cached to avoid repeated computation
  String getFormattedLocation() {
    if (_currentForecast == null) return '';

    final reachId = _currentForecast!.reach.reachId;

    // Return cached value if available
    if (_formattedLocationCache.containsKey(reachId)) {
      return _formattedLocationCache[reachId]!;
    }

    // Compute and cache - use the improved subtitle formatter
    final location = _currentForecast!.reach.formattedLocationSubtitle;
    _formattedLocationCache[reachId] = location;
    return location;
  }

  // Use cached values
  /// Get available forecast types - now with caching
  List<String> getAvailableForecastTypes() {
    if (_currentForecast == null) return [];

    final reachId = _currentForecast!.reach.reachId;

    // Return cached value if available
    if (_availableForecastTypesCache.containsKey(reachId)) {
      return _availableForecastTypesCache[reachId]!;
    }

    // Compute and cache
    final types = _forecastService.getAvailableForecastTypes(_currentForecast!);
    _availableForecastTypesCache[reachId] = types;
    return types;
  }

  /// Check if current reach has ensemble data
  bool hasEnsembleData() {
    if (_currentForecast == null) return false;
    return _forecastService.hasEnsembleData(_currentForecast!);
  }

  /// Clear current data
  void clear() {
    _currentForecast = null;
    _sessionCache.clear();
    _clearAllComputedCaches();
    _clearError();
    _setLoadingPhase('none');
    _resetAllLoadingStates();
    notifyListeners();
  }

  /// Clear error message
  void clearError() {
    _clearError();
  }

  /// Get cache statistics for debugging
  Future<Map<String, dynamic>> getCacheStats() async {
    final diskStats = await _forecastService.getCacheStats();
    return {
      'sessionCached': _sessionCache.length,
      'sessionReaches': _sessionCache.keys.toList(),
      'diskCache': diskStats,
      'computedCaches': {
        'currentFlow': _currentFlowCache.length,
        'flowCategory': _flowCategoryCache.length,
        'formattedLocation': _formattedLocationCache.length,
        'availableForecastTypes': _availableForecastTypesCache.length,
      },
    };
  }

  /// Get hourly data for short-range forecast with calculated trends
  List<HourlyFlowDataPoint> getShortRangeHourlyData() {
    if (_currentForecast == null) return [];
    return _forecastService.getShortRangeHourlyData(_currentForecast!);
  }

  /// Get ALL hourly data for charts (including past hours)
  List<HourlyFlowDataPoint> getAllShortRangeHourlyData() {
    if (_currentForecast == null) return [];
    return _forecastService.getAllShortRangeHourlyData(_currentForecast!);
  }

  // Update all computed caches when data changes
  void _updateComputedCaches(String reachId) {
    if (_currentForecast == null) return;

    // Pre-compute commonly used values
    getCurrentFlow(); // This will cache the result
    getFlowCategory(); // This will cache the result
    getFormattedLocation(); // This will cache the result
    getAvailableForecastTypes(); // This will cache the result
  }

  // Clear computed caches for specific reach
  void _clearComputedCaches(String reachId) {
    _currentFlowCache.removeWhere((key, value) => key.startsWith(reachId));
    _flowCategoryCache.removeWhere((key, value) => key.startsWith(reachId));
    _formattedLocationCache.remove(reachId);
    _availableForecastTypesCache.remove(reachId);
  }

  /// Clear unit-dependent cached values (call when unit preference changes)
  void clearUnitDependentCaches() {
    // Clear flow and category caches (these depend on units)
    _currentFlowCache.clear();
    _flowCategoryCache.clear();

    // FIXED: Also clear session cache since it may contain unconverted data
    _sessionCache.clear();

    // Also clear ForecastService unit-dependent caches
    _forecastService.clearUnitDependentCaches();

    // Trigger UI update to refresh displayed values
    notifyListeners();
  }

  // Clear all computed caches
  void _clearAllComputedCaches() {
    _currentFlowCache.clear();
    _flowCategoryCache.clear();
    _formattedLocationCache.clear();
    _availableForecastTypesCache.clear();
  }

  // Helper methods
  void _setLoading(bool loading) {
    if (_isLoading != loading) {
      _isLoading = loading;
      notifyListeners();
    }
  }

  // Selective loading state setters
  void _setLoadingOverview(bool loading) {
    if (_isLoadingOverview != loading) {
      _isLoadingOverview = loading;
      notifyListeners();
    }
  }

  void _setLoadingSupplementary(bool loading) {
    if (_isLoadingSupplementary != loading) {
      _isLoadingSupplementary = loading;
      notifyListeners();
    }
  }

  // Individual forecast category loading state setters
  void _setLoadingHourly(bool loading) {
    if (_isLoadingHourly != loading) {
      _isLoadingHourly = loading;
      notifyListeners();
    }
  }

  void _setLoadingDaily(bool loading) {
    if (_isLoadingDaily != loading) {
      _isLoadingDaily = loading;
      notifyListeners();
    }
  }

  void _setLoadingExtended(bool loading) {
    if (_isLoadingExtended != loading) {
      _isLoadingExtended = loading;
      notifyListeners();
    }
  }

  // Reset all loading states
  void _resetAllLoadingStates() {
    _isLoading = false;
    _isLoadingOverview = false;
    _isLoadingSupplementary = false;
    _isLoadingHourly = false;
    _isLoadingDaily = false;
    _isLoadingExtended = false;
  }

  void _setLoadingPhase(String phase) {
    if (_loadingPhase != phase) {
      _loadingPhase = phase;
      notifyListeners();
    }
  }

  void _setError(String error) {
    _errorMessage = error;
    notifyListeners();
  }

  void _clearError() {
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }
}
