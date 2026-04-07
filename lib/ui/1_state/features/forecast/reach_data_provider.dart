// lib/ui/1_state/features/forecast/reach_data_provider.dart

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_overview_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_supplementary_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_specific_forecast_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_complete_forecast_usecase.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_cache_mixin.dart';

/// State management for reach and forecast data
/// Now with phased loading and progressive forecast category loading
class ReachDataProvider with ChangeNotifier, ReachDataCacheMixin {
  final IForecastService _forecastService;
  final LoadForecastOverviewUseCase _loadOverview;
  final LoadForecastSupplementaryUseCase _loadSupplementary;
  final LoadSpecificForecastUseCase _loadSpecificForecast;
  final LoadCompleteForecastUseCase _loadComplete;

  ReachDataProvider({
    IForecastService? forecastService,
    LoadForecastOverviewUseCase? loadOverview,
    LoadForecastSupplementaryUseCase? loadSupplementary,
    LoadSpecificForecastUseCase? loadSpecificForecast,
    LoadCompleteForecastUseCase? loadComplete,
  })  : _forecastService = forecastService ?? GetIt.I<IForecastService>(),
        _loadOverview =
            loadOverview ?? GetIt.I<LoadForecastOverviewUseCase>(),
        _loadSupplementary =
            loadSupplementary ?? GetIt.I<LoadForecastSupplementaryUseCase>(),
        _loadSpecificForecast =
            loadSpecificForecast ?? GetIt.I<LoadSpecificForecastUseCase>(),
        _loadComplete =
            loadComplete ?? GetIt.I<LoadCompleteForecastUseCase>();

  // Mixin abstract getters
  @override
  IForecastService get forecastService => _forecastService;

  @override
  ForecastResponse? get currentForecast => _currentForecast;

  // Generation counter — incremented on every navigation-away / clear so that
  // in-flight futures can detect they are stale and discard their results.
  int _loadingGeneration = 0;

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

  // Getters
  bool get isLoading => _isLoading;
  bool get isLoadingOverview => _isLoadingOverview;
  bool get isLoadingSupplementary => _isLoadingSupplementary;
  String get loadingPhase => _loadingPhase;
  String? get errorMessage => _errorMessage;
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
    _loadingGeneration++; // Invalidate any in-flight requests
    _currentForecast = null;
    clearAllComputedCaches();
    _errorMessage = null;
    _loadingPhase = 'none';
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
    final gen = ++_loadingGeneration;
    _setLoadingOverview(true);
    _setLoadingPhase('overview');
    _clearError();

    try {
      // Check session cache first
      if (sessionCache.containsKey(reachId)) {
        AppLogger.debug('ReachProvider', 'Using cached data for overview: $reachId');
        if (gen != _loadingGeneration) return false;
        _currentForecast = sessionCache[reachId];
        updateComputedCaches(reachId);
        _setLoadingOverview(false);
        _setLoadingPhase('complete'); // If cached, we have complete data
        return true;
      }

      // Load overview data via use case
      final result = await _loadOverview(reachId);

      if (gen != _loadingGeneration) return false; // Stale — discard

      if (result.isFailure) {
        _setError(result.errorMessage ?? 'Failed to load overview');
        _setLoadingOverview(false);
        _setLoadingPhase('none');
        return false;
      }

      _currentForecast = result.data;
      updateComputedCaches(reachId);

      _setLoadingOverview(false);
      _setLoadingPhase('overview');
      return true;
    } catch (e) {
      AppLogger.error('ReachProvider', 'Error loading overview data', e);
      if (gen != _loadingGeneration) return false;
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

      // Load hourly data via use case
      final result = await _loadSpecificForecast(reachId, 'short_range');

      if (result.isFailure) {
        AppLogger.error(
          'ReachProvider',
          'Error loading hourly forecast: ${result.errorMessage}',
        );
        _setLoadingHourly(false);
        return false;
      }

      // Merge with existing data instead of overwriting
      _currentForecast = _mergeForecastData(_currentForecast!, result.data);
      sessionCache[reachId] = _currentForecast!;
      updateComputedCaches(reachId);

      _setLoadingHourly(false);
      return true;
    } catch (e) {
      AppLogger.error('ReachProvider', 'Error loading hourly forecast', e);
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

      // Load daily data via use case
      final result = await _loadSpecificForecast(reachId, 'medium_range');

      if (result.isFailure) {
        AppLogger.error(
          'ReachProvider',
          'Error loading daily forecast: ${result.errorMessage}',
        );
        _setLoadingDaily(false);
        return false;
      }

      // Merge with existing data instead of overwriting
      _currentForecast = _mergeForecastData(_currentForecast!, result.data);
      sessionCache[reachId] = _currentForecast!;
      updateComputedCaches(reachId);

      _setLoadingDaily(false);
      return true;
    } catch (e) {
      AppLogger.error('ReachProvider', 'Error loading daily forecast', e);
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

      // Load extended data via use case
      final result = await _loadSpecificForecast(reachId, 'long_range');

      if (result.isFailure) {
        AppLogger.error(
          'ReachProvider',
          'Error loading extended forecast: ${result.errorMessage}',
        );
        _setLoadingExtended(false);
        return false;
      }

      // Merge with existing data instead of overwriting
      _currentForecast = _mergeForecastData(
        _currentForecast!,
        result.data,
      );
      sessionCache[reachId] = _currentForecast!;
      updateComputedCaches(reachId);

      _setLoadingExtended(false);
      return true;
    } catch (e) {
      AppLogger.error('ReachProvider', 'Error loading extended forecast', e);
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
    sessionCache.remove(reachId);
    clearComputedCachesForReach(reachId);
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
      AppLogger.error('ReachProvider', 'Error in comprehensive refresh', e);
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

    final gen = ++_loadingGeneration;
    _setLoadingSupplementary(true);
    _clearError();

    try {
      // Enhance existing data with supplementary information via use case
      final result = await _loadSupplementary(reachId, _currentForecast!);

      if (gen != _loadingGeneration) return false; // Stale — discard

      if (result.isFailure) {
        // Don't set error - supplementary data is not critical
        // Keep existing overview data
        _setLoadingSupplementary(false);
        _setLoadingPhase('overview'); // Still have overview data
        return false;
      }

      _currentForecast = result.data;
      sessionCache[reachId] = result.data; // Update cache

      // Update computed caches
      updateComputedCaches(reachId);

      _setLoadingSupplementary(false);
      _setLoadingPhase('complete');
      return true;
    } catch (e) {
      // Don't set error - supplementary data is not critical
      // Keep existing overview data
      if (gen != _loadingGeneration) return false;
      _setLoadingSupplementary(false);
      _setLoadingPhase('overview'); // Still have overview data
      return false; // Indicate supplementary loading failed, but don't break UI
    }
  }

  // Keep for backwards compatibility and complete loading
  /// Load complete reach and forecast data
  Future<bool> loadReach(String reachId) async {
    final gen = ++_loadingGeneration;
    _setLoading(true);
    _setLoadingPhase('complete');
    _clearError();

    try {
      // Check session cache first
      if (sessionCache.containsKey(reachId)) {
        if (gen != _loadingGeneration) return false;
        _currentForecast = sessionCache[reachId];
        updateComputedCaches(reachId);
        _setLoading(false);
        _setLoadingPhase('complete');
        return true;
      }

      // Load from use case (uses disk cache automatically)
      final result = await _loadComplete(reachId);

      if (gen != _loadingGeneration) return false; // Stale — discard

      if (result.isFailure) {
        _setError(result.errorMessage ?? 'Failed to load forecast data');
        _setLoading(false);
        _setLoadingPhase('none');
        return false;
      }

      _currentForecast = result.data;
      sessionCache[reachId] = result.data; // Cache for session
      updateComputedCaches(reachId);

      _setLoading(false);
      _setLoadingPhase('complete');
      return true;
    } catch (e) {
      AppLogger.error('ReachProvider', 'Error loading complete data', e);
      if (gen != _loadingGeneration) return false;
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
      final result = await _loadSpecificForecast(reachId, forecastType);

      if (result.isFailure) {
        _setError(result.errorMessage ?? 'Failed to load forecast');
        _setLoading(false);
        _setLoadingPhase('none');
        return false;
      }

      _currentForecast = result.data;
      sessionCache[reachId] = result.data;
      updateComputedCaches(reachId);

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

  /// Clear current data
  void clear() {
    _currentForecast = null;
    sessionCache.clear();
    clearAllComputedCaches();
    _errorMessage = null;
    _loadingPhase = 'none';
    _resetAllLoadingStates();
    notifyListeners();
  }

  /// Clear error message
  void clearError() {
    _clearError();
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
    if (_errorMessage != error) {
      _errorMessage = error;
      notifyListeners();
    }
  }

  void _clearError() {
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }
}
