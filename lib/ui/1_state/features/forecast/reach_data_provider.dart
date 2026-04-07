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
import 'package:rivr/ui/1_state/shared/section_load_state.dart';

/// State management for reach and forecast data.
///
/// Phase 4: All data requests fire in parallel after overview loads.
/// Each section merges independently and notifies the UI as it arrives.
/// Current flow recalculates after each merge (short → medium → long priority).
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

  // Expose for testing
  @visibleForTesting
  int get loadingGeneration => _loadingGeneration;

  // Current state
  bool _isLoading = false;
  String? _errorMessage;
  ForecastResponse? _currentForecast;

  // Phased loading states
  bool _isLoadingOverview = false;
  bool _isLoadingSupplementary = false;
  String _loadingPhase =
      'none'; // 'none', 'overview', 'supplementary', 'complete'

  // Per-section load states (Phase 2)
  SectionLoadState _hourlyState = SectionLoadState.idle;
  SectionLoadState _dailyState = SectionLoadState.idle;
  SectionLoadState _extendedState = SectionLoadState.idle;
  SectionLoadState _returnPeriodsState = SectionLoadState.idle;

  // Getters
  bool get isLoading => _isLoading;
  bool get isLoadingOverview => _isLoadingOverview;
  bool get isLoadingSupplementary => _isLoadingSupplementary;
  String get loadingPhase => _loadingPhase;
  String? get errorMessage => _errorMessage;
  bool get hasData => _currentForecast != null;

  // Per-section state getters
  SectionLoadState get hourlyState => _hourlyState;
  SectionLoadState get dailyState => _dailyState;
  SectionLoadState get extendedState => _extendedState;
  SectionLoadState get returnPeriodsState => _returnPeriodsState;

  // Backward-compatible boolean getters (derived from section states)
  bool get isLoadingHourly => _hourlyState.isLoading;
  bool get isLoadingDaily => _dailyState.isLoading;
  bool get isLoadingExtended => _extendedState.isLoading;

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
        'loading': _hourlyState.isLoading,
        'available': hasHourlyForecast,
        'state': _hourlyState,
        'type': 'short_range',
      },
      'daily': {
        'loading': _dailyState.isLoading,
        'available': hasDailyForecast,
        'state': _dailyState,
        'type': 'medium_range',
      },
      'extended': {
        'loading': _extendedState.isLoading,
        'available': hasExtendedForecast,
        'state': _extendedState,
        'type': 'long_range',
      },
    };
  }

  /// Get the [SectionLoadState] for a given forecast type.
  SectionLoadState getSectionState(String forecastType) {
    switch (forecastType) {
      case 'short_range':
        return _hourlyState;
      case 'medium_range':
        return _dailyState;
      case 'long_range':
        return _extendedState;
      default:
        return SectionLoadState.idle;
    }
  }

  // ---------------------------------------------------------------------------
  // Phase 4 — Primary entry point: parallel, non-blocking data loading
  // ---------------------------------------------------------------------------

  /// Load all data for a reach. Overview loads first (awaited), then all
  /// forecast sections + supplementary fire in parallel. Returns `true` when
  /// overview is available. Parallel loads continue in the background —
  /// each one merges and notifies the UI independently as it resolves.
  Future<bool> loadAllData(String reachId) async {
    final gen = ++_loadingGeneration;
    _clearError();

    // Fast path: session cache has complete data
    if (sessionCache.containsKey(reachId)) {
      AppLogger.debug('ReachProvider', 'Using cached data for: $reachId');
      if (gen != _loadingGeneration) return false;
      _currentForecast = sessionCache[reachId];
      updateComputedCaches(reachId);
      _markAllSectionsFromCache();
      _setLoadingPhase('complete');
      return true;
    }

    // Step 1: Load overview (required base) — must complete first
    _setLoadingOverview(true);
    _setSectionState('short_range', SectionLoadState.loading);
    _setSectionState('medium_range', SectionLoadState.loading);
    _setSectionState('long_range', SectionLoadState.loading);
    _returnPeriodsState = SectionLoadState.loading;

    try {
      final overviewResult = await _loadOverview(reachId);
      if (gen != _loadingGeneration) return false;

      if (overviewResult.isFailure) {
        _setError(overviewResult.errorMessage ?? 'Failed to load overview');
        _setLoadingOverview(false);
        _setSectionState('short_range', SectionLoadState.error);
        _setSectionState('medium_range', SectionLoadState.error);
        _setSectionState('long_range', SectionLoadState.error);
        _returnPeriodsState = SectionLoadState.error;
        _setLoadingPhase('none');
        return false;
      }

      _currentForecast = overviewResult.data;
      updateComputedCaches(reachId);
      _setLoadingOverview(false);
      _setLoadingPhase('overview');

      // Step 2: Fire all remaining requests in parallel (non-blocking)
      _fireParallelLoads(reachId, gen);

      return true; // Overview available — UI can render immediately
    } catch (e) {
      if (gen != _loadingGeneration) return false;
      AppLogger.error('ReachProvider', 'Error in loadAllData overview', e);
      _setError(e.toString());
      _setLoadingOverview(false);
      _setLoadingPhase('none');
      return false;
    }
  }

  /// Fire all section loads + supplementary in parallel.
  /// Each one handles its own errors and notifies independently.
  void _fireParallelLoads(String reachId, int gen) {
    _loadSectionParallel(reachId, 'short_range', gen);
    _loadSectionParallel(reachId, 'medium_range', gen);
    _loadSectionParallel(reachId, 'long_range', gen);
    _loadSupplementaryParallel(reachId, gen);
  }

  /// Load a single forecast section in parallel-safe mode.
  /// Checks generation for cancellation, merges result, recalculates current
  /// flow, and notifies the UI.
  Future<void> _loadSectionParallel(
    String reachId,
    String forecastType,
    int gen,
  ) async {
    try {
      final result = await _loadSpecificForecast(reachId, forecastType);
      if (gen != _loadingGeneration) return; // Stale — discard

      if (result.isFailure) {
        AppLogger.error(
          'ReachProvider',
          'Error loading $forecastType: ${result.errorMessage}',
        );
        _setSectionState(forecastType, SectionLoadState.error);
        return;
      }

      // Merge into existing forecast (thread-safe in Dart's single-threaded
      // event loop — each microtask runs atomically)
      _currentForecast = _mergeForecastData(_currentForecast!, result.data);

      // Clear flow caches and recalculate — current flow may now come from
      // this section if a higher-priority section was empty
      clearFlowCachesForReach(reachId);
      updateComputedCaches(reachId);

      // Update session cache
      sessionCache[reachId] = _currentForecast!;

      // Set section state
      final hasData = _hasSectionData(forecastType);
      _setSectionState(
        forecastType,
        hasData ? SectionLoadState.loaded : SectionLoadState.empty,
      );

      _checkAllComplete();
    } catch (e) {
      if (gen != _loadingGeneration) return;
      AppLogger.error('ReachProvider', 'Error loading $forecastType', e);
      _setSectionState(forecastType, SectionLoadState.error);
      _checkAllComplete();
    }
  }

  /// Load supplementary data (return periods) in parallel-safe mode.
  /// Merges only the reach data (with return periods) — does NOT overwrite
  /// forecast sections that may have been merged by other parallel loads.
  Future<void> _loadSupplementaryParallel(String reachId, int gen) async {
    _setLoadingSupplementary(true);

    try {
      final result = await _loadSupplementary(reachId, _currentForecast!);
      if (gen != _loadingGeneration) return;

      if (result.isFailure) {
        _setLoadingSupplementary(false);
        _returnPeriodsState = SectionLoadState.error;
        _checkAllComplete();
        return;
      }

      // Merge only the reach data (return periods) — preserve forecast sections
      _mergeSupplementaryData(result.data);
      updateComputedCaches(reachId);
      sessionCache[reachId] = _currentForecast!;

      _setLoadingSupplementary(false);
      _returnPeriodsState = hasSupplementaryData
          ? SectionLoadState.loaded
          : SectionLoadState.empty;
      _checkAllComplete();
    } catch (e) {
      if (gen != _loadingGeneration) return;
      _setLoadingSupplementary(false);
      _returnPeriodsState = SectionLoadState.error;
      _checkAllComplete();
    }
  }

  /// Merge supplementary result (return periods) without overwriting
  /// forecast sections that other parallel loads may have populated.
  void _mergeSupplementaryData(ForecastResponse supplementary) {
    if (_currentForecast == null) return;
    _currentForecast = ForecastResponse(
      reach: supplementary.reach, // Has return periods
      shortRange: _currentForecast!.shortRange,
      mediumRange: _currentForecast!.mediumRange,
      longRange: _currentForecast!.longRange,
      analysisAssimilation: _currentForecast!.analysisAssimilation,
      mediumRangeBlend: _currentForecast!.mediumRangeBlend,
    );
  }

  /// Check if ALL sections are done loading; if so, set phase to 'complete'.
  void _checkAllComplete() {
    if (_hourlyState.isDone &&
        _dailyState.isDone &&
        _extendedState.isDone &&
        _returnPeriodsState.isDone) {
      _setLoadingPhase('complete');
    }
  }

  /// Set section states from cached data (all sections are already populated).
  void _markAllSectionsFromCache() {
    _hourlyState =
        hasHourlyForecast ? SectionLoadState.loaded : SectionLoadState.empty;
    _dailyState =
        hasDailyForecast ? SectionLoadState.loaded : SectionLoadState.empty;
    _extendedState =
        hasExtendedForecast ? SectionLoadState.loaded : SectionLoadState.empty;
    _returnPeriodsState =
        hasSupplementaryData ? SectionLoadState.loaded : SectionLoadState.empty;
    _isLoadingOverview = false;
    _isLoadingSupplementary = false;
    notifyListeners();
  }

  /// Check if a section has data.
  bool _hasSectionData(String forecastType) {
    switch (forecastType) {
      case 'short_range':
        return hasHourlyForecast;
      case 'medium_range':
        return hasDailyForecast;
      case 'long_range':
        return hasExtendedForecast;
      default:
        return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Individual section loaders (used by detail page refresh buttons)
  // ---------------------------------------------------------------------------

  /// Load overview data only (reach info + current flow).
  Future<bool> loadOverviewData(String reachId) async {
    final gen = ++_loadingGeneration;
    _setLoadingOverview(true);
    _setLoadingPhase('overview');
    _clearError();

    try {
      if (sessionCache.containsKey(reachId)) {
        AppLogger.debug(
          'ReachProvider',
          'Using cached data for overview: $reachId',
        );
        if (gen != _loadingGeneration) return false;
        _currentForecast = sessionCache[reachId];
        updateComputedCaches(reachId);
        _setLoadingOverview(false);
        _setLoadingPhase('complete');
        return true;
      }

      final result = await _loadOverview(reachId);
      if (gen != _loadingGeneration) return false;

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

  /// Load hourly forecast (short-range) — standalone for detail page refresh.
  Future<bool> loadHourlyForecast(String reachId) async {
    _setSectionState('short_range', SectionLoadState.loading);

    try {
      if (_currentForecast == null) {
        final overviewSuccess = await loadOverviewData(reachId);
        if (!overviewSuccess) {
          _setSectionState('short_range', SectionLoadState.error);
          return false;
        }
      }

      final result = await _loadSpecificForecast(reachId, 'short_range');

      if (result.isFailure) {
        AppLogger.error(
          'ReachProvider',
          'Error loading hourly forecast: ${result.errorMessage}',
        );
        _setSectionState('short_range', SectionLoadState.error);
        return false;
      }

      _currentForecast = _mergeForecastData(_currentForecast!, result.data);
      clearFlowCachesForReach(reachId);
      sessionCache[reachId] = _currentForecast!;
      updateComputedCaches(reachId);

      _setSectionState(
        'short_range',
        hasHourlyForecast ? SectionLoadState.loaded : SectionLoadState.empty,
      );
      return hasHourlyForecast;
    } catch (e) {
      AppLogger.error('ReachProvider', 'Error loading hourly forecast', e);
      _setSectionState('short_range', SectionLoadState.error);
      return false;
    }
  }

  /// Load daily forecast (medium-range) — standalone for detail page refresh.
  Future<bool> loadDailyForecast(String reachId) async {
    _setSectionState('medium_range', SectionLoadState.loading);

    try {
      if (_currentForecast == null) {
        final overviewSuccess = await loadOverviewData(reachId);
        if (!overviewSuccess) {
          _setSectionState('medium_range', SectionLoadState.error);
          return false;
        }
      }

      final result = await _loadSpecificForecast(reachId, 'medium_range');

      if (result.isFailure) {
        AppLogger.error(
          'ReachProvider',
          'Error loading daily forecast: ${result.errorMessage}',
        );
        _setSectionState('medium_range', SectionLoadState.error);
        return false;
      }

      _currentForecast = _mergeForecastData(_currentForecast!, result.data);
      clearFlowCachesForReach(reachId);
      sessionCache[reachId] = _currentForecast!;
      updateComputedCaches(reachId);

      _setSectionState(
        'medium_range',
        hasDailyForecast ? SectionLoadState.loaded : SectionLoadState.empty,
      );
      return hasDailyForecast;
    } catch (e) {
      AppLogger.error('ReachProvider', 'Error loading daily forecast', e);
      _setSectionState('medium_range', SectionLoadState.error);
      return false;
    }
  }

  /// Load extended forecast (long-range) — standalone for detail page refresh.
  Future<bool> loadExtendedForecast(String reachId) async {
    _setSectionState('long_range', SectionLoadState.loading);

    try {
      if (_currentForecast == null) {
        final overviewSuccess = await loadOverviewData(reachId);
        if (!overviewSuccess) {
          _setSectionState('long_range', SectionLoadState.error);
          return false;
        }
      }

      final result = await _loadSpecificForecast(reachId, 'long_range');

      if (result.isFailure) {
        AppLogger.error(
          'ReachProvider',
          'Error loading extended forecast: ${result.errorMessage}',
        );
        _setSectionState('long_range', SectionLoadState.error);
        return false;
      }

      _currentForecast = _mergeForecastData(_currentForecast!, result.data);
      clearFlowCachesForReach(reachId);
      sessionCache[reachId] = _currentForecast!;
      updateComputedCaches(reachId);

      _setSectionState(
        'long_range',
        hasExtendedForecast ? SectionLoadState.loaded : SectionLoadState.empty,
      );
      return hasExtendedForecast;
    } catch (e) {
      AppLogger.error('ReachProvider', 'Error loading extended forecast', e);
      _setSectionState('long_range', SectionLoadState.error);
      return false;
    }
  }

  /// Load supplementary data (return periods) — standalone.
  Future<bool> loadSupplementaryData(String reachId) async {
    if (_currentForecast == null) {
      final success = await loadOverviewData(reachId);
      if (!success) return false;
    }

    final gen = ++_loadingGeneration;
    _setLoadingSupplementary(true);
    _returnPeriodsState = SectionLoadState.loading;
    _clearError();

    try {
      final result = await _loadSupplementary(reachId, _currentForecast!);
      if (gen != _loadingGeneration) return false;

      if (result.isFailure) {
        _setLoadingSupplementary(false);
        _returnPeriodsState = SectionLoadState.error;
        return false;
      }

      _mergeSupplementaryData(result.data);
      sessionCache[reachId] = _currentForecast!;
      updateComputedCaches(reachId);

      _setLoadingSupplementary(false);
      _returnPeriodsState = hasSupplementaryData
          ? SectionLoadState.loaded
          : SectionLoadState.empty;
      _setLoadingPhase('complete');
      return true;
    } catch (e) {
      if (gen != _loadingGeneration) return false;
      _setLoadingSupplementary(false);
      _returnPeriodsState = SectionLoadState.error;
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Refresh & utility methods
  // ---------------------------------------------------------------------------

  /// Comprehensive refresh — clears caches and reloads everything in parallel.
  Future<bool> comprehensiveRefresh(String reachId) async {
    sessionCache.remove(reachId);
    clearComputedCachesForReach(reachId);
    _forecastService.clearComputedCaches();

    return await loadAllData(reachId);
  }

  // Merge forecast data properly (preserves existing data)
  ForecastResponse _mergeForecastData(
    ForecastResponse existing,
    ForecastResponse newData,
  ) {
    return ForecastResponse(
      reach: existing.reach,
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

  /// Load complete reach and forecast data (backward compat).
  Future<bool> loadReach(String reachId) async {
    final gen = ++_loadingGeneration;
    _setLoading(true);
    _setLoadingPhase('complete');
    _clearError();

    try {
      if (sessionCache.containsKey(reachId)) {
        if (gen != _loadingGeneration) return false;
        _currentForecast = sessionCache[reachId];
        updateComputedCaches(reachId);
        _setLoading(false);
        _setLoadingPhase('complete');
        return true;
      }

      final result = await _loadComplete(reachId);
      if (gen != _loadingGeneration) return false;

      if (result.isFailure) {
        _setError(result.errorMessage ?? 'Failed to load forecast data');
        _setLoading(false);
        _setLoadingPhase('none');
        return false;
      }

      _currentForecast = result.data;
      sessionCache[reachId] = result.data;
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

  /// Load specific forecast type only (used by detail page template).
  Future<bool> loadSpecificForecast(
    String reachId,
    String forecastType,
  ) async {
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

  /// Force refresh current reach (bypass all caches).
  Future<bool> refreshCurrentReach() async {
    if (_currentForecast == null) return false;
    final reachId = _currentForecast!.reach.reachId;
    return await comprehensiveRefresh(reachId);
  }

  /// Clear current data.
  void clear() {
    _currentForecast = null;
    sessionCache.clear();
    clearAllComputedCaches();
    _errorMessage = null;
    _loadingPhase = 'none';
    _resetAllLoadingStates();
    notifyListeners();
  }

  /// Clear error message.
  void clearError() {
    _clearError();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _setLoading(bool loading) {
    if (_isLoading != loading) {
      _isLoading = loading;
      notifyListeners();
    }
  }

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

  void _setSectionState(String forecastType, SectionLoadState state) {
    switch (forecastType) {
      case 'short_range':
        if (_hourlyState != state) {
          _hourlyState = state;
          notifyListeners();
        }
      case 'medium_range':
        if (_dailyState != state) {
          _dailyState = state;
          notifyListeners();
        }
      case 'long_range':
        if (_extendedState != state) {
          _extendedState = state;
          notifyListeners();
        }
    }
  }

  void _resetAllLoadingStates() {
    _isLoading = false;
    _isLoadingOverview = false;
    _isLoadingSupplementary = false;
    _hourlyState = SectionLoadState.idle;
    _dailyState = SectionLoadState.idle;
    _extendedState = SectionLoadState.idle;
    _returnPeriodsState = SectionLoadState.idle;
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
