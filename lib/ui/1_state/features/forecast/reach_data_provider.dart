// lib/ui/1_state/features/forecast/reach_data_provider.dart

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/hourly_flow_data.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/3_datasources/shared/dtos/reach_data_dto.dart';
import 'package:rivr/services/4_infrastructure/forecast/forecast_values.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_forecast_payload.dart';
import 'package:rivr/ui/1_state/shared/section_load_state.dart';

/// State management for reach and forecast data (ADR 0011 Phase 3).
///
/// Rewired onto `IRiverDataRepository` — the ONE data path. Before this phase
/// the provider owned a session cache, a private disk cache
/// (the legacy forecast disk cache) and its own SWR loop, duplicating what the
/// repository already does; two caches with different TTLs holding the same
/// reach is the divergence ADR 0011 exists to remove. Now:
///
///  - every value comes from `repo.read` (memory → disk → network, SWR built
///    in, one in-flight fetch per key shared app-wide — so this provider and
///    the map sheet reading the same reach cost ONE fetch, guard 3);
///  - the provider holds NO value cache of its own; display values are pure
///    derivations over the decoded response (`ForecastValues`), computed per
///    call (guard 5: exactly one cache holds forecast values);
///  - a unit flip re-decodes the same cached entries — `recomputeForUnitChange`
///    notifies, decode converts, nothing refetches (guard 4);
///  - background revalidations land through the repository's watch listenables,
///    so every surface showing this reach updates together (guard 2).
///
/// The public API is source-compatible for all consumers; ONE behavioural
/// change is deliberate and documented on [loadReach]: completeness is no
/// longer awaited — sections merge as they land, and listeners re-derive.
class ReachDataProvider with ChangeNotifier {
  final IRiverDataRepository _repo;
  final IFlowUnitPreferenceService _unitService;

  ReachDataProvider({
    IRiverDataRepository? repository,
    IFlowUnitPreferenceService? unitService,
  })  : _repo = repository ?? GetIt.I<IRiverDataRepository>(),
        _unitService = unitService ?? GetIt.I<IFlowUnitPreferenceService>();

  // Generation counter — incremented on every navigation-away / clear so that
  // in-flight futures can detect they are stale and discard their results.
  int _loadingGeneration = 0;

  @visibleForTesting
  int get loadingGeneration => _loadingGeneration;

  // Current state
  bool _isLoading = false;
  String? _errorMessage;
  ForecastResponse? _currentForecast;
  String? _currentReachId;

  // Phased loading states
  bool _isLoadingOverview = false;
  bool _isLoadingSupplementary = false;
  String _loadingPhase = 'none'; // 'none', 'overview', 'supplementary', 'complete'

  // Per-section load states
  SectionLoadState _hourlyState = SectionLoadState.idle;
  SectionLoadState _dailyState = SectionLoadState.idle;
  SectionLoadState _extendedState = SectionLoadState.idle;
  SectionLoadState _returnPeriodsState = SectionLoadState.idle;

  // Watch subscriptions on the current reach's products, so a background
  // revalidation (this surface's or ANY surface's) merges into the open page.
  final List<VoidCallback> _watchDetachers = [];

  // Getters — unchanged public API.
  bool get isLoading => _isLoading;
  bool get isLoadingOverview => _isLoadingOverview;
  bool get isLoadingSupplementary => _isLoadingSupplementary;
  /// Exercised by tests; no lib/ caller today — kept as the public read of
  /// the phase machine the section states summarise.
  String get loadingPhase => _loadingPhase;
  String? get errorMessage => _errorMessage;
  bool get hasData => _currentForecast != null;

  SectionLoadState get hourlyState => _hourlyState;
  SectionLoadState get dailyState => _dailyState;
  SectionLoadState get extendedState => _extendedState;
  SectionLoadState get returnPeriodsState => _returnPeriodsState;

  ForecastResponse? get currentForecast => _currentForecast;
  ReachData? get currentReach => _currentForecast?.reach;

  bool get hasOverviewData =>
      _currentForecast != null && _currentForecast!.reach.hasLocationData;
  bool get hasSupplementaryData =>
      _currentForecast?.reach.hasReturnPeriods ?? false;
  bool get hasHourlyForecast => _currentForecast?.shortRange?.isNotEmpty ?? false;
  bool get hasDailyForecast => _currentForecast?.mediumRange.isNotEmpty ?? false;
  bool get hasExtendedForecast => _currentForecast?.longRange.isNotEmpty ?? false;

  // ---------------------------------------------------------------------------
  // Display-value derivations — pure, per call, over the current response.
  // These replace the mixin's computed caches: the response is in memory, the
  // derivations are O(points), and caching them was a second place for a
  // value to live (guard 5).
  // ---------------------------------------------------------------------------

  double? getCurrentFlow({String? preferredType}) {
    final f = _currentForecast;
    if (f == null) return null;
    return ForecastValues.currentFlow(f, preferredType: preferredType);
  }

  String getFlowCategory({String? preferredType}) {
    final f = _currentForecast;
    if (f == null) return 'Unknown';
    return ForecastValues.flowCategory(f, _unitService,
        preferredType: preferredType);
  }

  
  
  
  List<HourlyFlowDataPoint> getShortRangeHourlyData() {
    final f = _currentForecast;
    if (f == null) return [];
    return ForecastValues.shortRangeHourlyData(f);
  }

  
  /// The unit preference changed. Nothing to clear and nothing to fetch: the
  /// cached entries hold native values, decode converts, and this rebuild
  /// re-derives every display value in the new unit (guard 4). The re-decode
  /// of the current reach happens here so `currentForecast` itself is in the
  /// new unit for consumers that read series directly.
  /// Backward-compatible name used by the unit-flip handler. Same semantics
  /// as [recomputeForUnitChange]: there are no unit-dependent caches left to
  /// clear — that is the point of the phase.
  void clearUnitDependentCaches() => recomputeForUnitChange();

  void recomputeForUnitChange() {
    final reachId = _currentReachId;
    if (reachId == null) {
      notifyListeners();
      return;
    }
    _redecodeFromCache(reachId);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Loading — every path is repo.read over the four NWM products.
  // ---------------------------------------------------------------------------

  RiverDataKey _keyFor(String reachId, ForecastProduct product) => RiverDataKey(
        source: ForecastSource.nwm,
        reachId: reachId,
        product: product,
      );

  static const _sectionProducts = {
    'short_range': ForecastProduct.shortRange,
    'medium_range': ForecastProduct.mediumRange,
    'long_range': ForecastProduct.longRange,
  };

  /// Load all data for a reach. The short-range read is awaited (it carries
  /// the reach info and current flow — the overview); medium, long and return
  /// periods land in parallel, each merging and notifying as it arrives.
  /// Returns true once the overview is available.
  Future<bool> loadAllData(String reachId) async {
    final gen = ++_loadingGeneration;
    _clearError();
    _beginReach(reachId);

    _setLoadingOverview(true);
    _setSectionState('short_range', SectionLoadState.loading);
    _setSectionState('medium_range', SectionLoadState.loading);
    _setSectionState('long_range', SectionLoadState.loading);
    _returnPeriodsState = SectionLoadState.loading;

    try {
      final entry = await _repo.read(_keyFor(reachId, ForecastProduct.shortRange));
      if (gen != _loadingGeneration) return false;

      final decoded =
          entry == null ? null : NwmForecastPayload.decode(entry, _unitService);
      if (decoded == null) {
        _setError('Failed to load overview');
        _setLoadingOverview(false);
        _setSectionState('short_range', SectionLoadState.error);
        _setSectionState('medium_range', SectionLoadState.error);
        _setSectionState('long_range', SectionLoadState.error);
        _returnPeriodsState = SectionLoadState.error;
        _setLoadingPhase('none');
        return false;
      }

      _currentForecast = decoded;
      _setLoadingOverview(false);
      _setSectionState('short_range',
          hasHourlyForecast ? SectionLoadState.loaded : SectionLoadState.empty);
      _setLoadingPhase('overview');

      // Remaining sections in parallel — each merges independently.
      _loadSectionParallel(reachId, 'medium_range', gen);
      _loadSectionParallel(reachId, 'long_range', gen);
      _loadReturnPeriodsParallel(reachId, gen);

      _attachWatches(reachId, gen);
      return true;
    } catch (e) {
      if (gen != _loadingGeneration) return false;
      AppLogger.error('ReachProvider', 'Error in loadAllData overview', e);
      _setError(e.toString());
      _setLoadingOverview(false);
      _setLoadingPhase('none');
      return false;
    }
  }

  Future<void> _loadSectionParallel(
    String reachId,
    String forecastType,
    int gen,
  ) async {
    try {
      final entry =
          await _repo.read(_keyFor(reachId, _sectionProducts[forecastType]!));
      if (gen != _loadingGeneration) return;

      final decoded =
          entry == null ? null : NwmForecastPayload.decode(entry, _unitService);
      if (decoded == null) {
        _setSectionState(forecastType, SectionLoadState.error);
        _checkAllComplete();
        return;
      }

      _currentForecast = _mergeForecastData(_currentForecast!, decoded);
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

  Future<void> _loadReturnPeriodsParallel(String reachId, int gen) async {
    _setLoadingSupplementary(true);
    try {
      final entry =
          await _repo.read(_keyFor(reachId, ForecastProduct.returnPeriods));
      if (gen != _loadingGeneration) return;

      _mergeReturnPeriods(entry);
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

  /// Merge a return-periods entry into the current reach. Native CMS in the
  /// payload; `ReturnPeriodPayload` owns the conversion, but here the reach
  /// model stores them native and converts at classification — matching the
  /// pre-rewire behaviour of `loadSupplementary`.
  void _mergeReturnPeriods(RiverDataEntry? entry) {
    final current = _currentForecast;
    if (current == null || entry == null) return;
    final raw = entry.payload['returnPeriods'];
    if (raw is! List || raw.isEmpty) return;
    try {
      final withRp = ReachDataDtoBridge.mergeReturnPeriods(current.reach, raw);
      _currentForecast = ForecastResponse(
        reach: withRp,
        shortRange: current.shortRange,
        mediumRange: current.mediumRange,
        longRange: current.longRange,
        analysisAssimilation: current.analysisAssimilation,
        mediumRangeBlend: current.mediumRangeBlend,
      );
    } catch (e) {
      AppLogger.warning('ReachProvider', 'Return-period merge failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Watches — background revalidations (from ANY surface) merge into the page.
  // ---------------------------------------------------------------------------

  void _attachWatches(String reachId, int gen) {
    _detachWatches();
    for (final e in _sectionProducts.entries) {
      final listenable = _repo.watch(_keyFor(reachId, e.value));
      void onChange() {
        if (gen != _loadingGeneration) return;
        final entry = listenable.value;
        if (entry == null) return;
        final decoded = NwmForecastPayload.decode(entry, _unitService);
        if (decoded == null || _currentForecast == null) return;
        _currentForecast = _mergeForecastData(_currentForecast!, decoded);
          notifyListeners();
      }

      listenable.addListener(onChange);
      _watchDetachers.add(() => listenable.removeListener(onChange));
    }
  }

  void _detachWatches() {
    for (final detach in _watchDetachers) {
      detach();
    }
    _watchDetachers.clear();
  }

  
  
  
  /// Load a reach (backward-compat name). The OVERVIEW is awaited — callers
  /// get a renderable page — and the remaining sections merge asynchronously
  /// as they land, exactly like [loadAllData] (it delegates there). Nothing
  /// may await this and then synchronously read mediumRange/longRange; widgets
  /// listen to the provider and re-derive on notify (see InteractiveChart's
  /// data-arrival re-extraction, review round 1 B1).
  Future<bool> loadReach(String reachId) async {
    _setLoading(true);
    try {
      final ok = await loadAllData(reachId);
      _setLoading(false);
      return ok;
    } catch (e) {
      AppLogger.error('ReachProvider', 'Error loading complete data', e);
      _setError(e.toString());
      _setLoading(false);
      _setLoadingPhase('none');
      return false;
    }
  }

  
  /// Comprehensive refresh — forced refetch of all four products through the
  /// one cache, then a normal load (which now hits the fresh entries).
  Future<bool> comprehensiveRefresh(String reachId) async {

    try {
      await Future.wait([
        _repo.refresh(_keyFor(reachId, ForecastProduct.shortRange)),
        _repo.refresh(_keyFor(reachId, ForecastProduct.mediumRange)),
        _repo.refresh(_keyFor(reachId, ForecastProduct.longRange)),
        _repo.refresh(_keyFor(reachId, ForecastProduct.returnPeriods)),
      ]);
    } catch (e) {
      AppLogger.warning('ReachProvider', 'Refresh fetch failed: $e');
      // loadAllData below still serves whatever the cache holds.
    }

    return loadAllData(reachId);
  }

  /// Force refresh current reach (bypass freshness).
  Future<bool> refreshCurrentReach() async {
    final reachId = _currentReachId;
    if (reachId == null) return false;
    return comprehensiveRefresh(reachId);
  }

  // ---------------------------------------------------------------------------
  // Clearing
  // ---------------------------------------------------------------------------

  
  /// Clear current data.
  void clear() {
    _loadingGeneration++;
    _detachWatches();
    _currentForecast = null;
    _currentReachId = null;
    _errorMessage = null;
    _loadingPhase = 'none';
    _resetAllLoadingStates();
    notifyListeners();
  }

  void clearError() => _clearError();

  // ---------------------------------------------------------------------------
  // Section-state summaries — unchanged public API.
  // ---------------------------------------------------------------------------

  
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
  // Internals
  // ---------------------------------------------------------------------------

  void _beginReach(String reachId) {
    if (_currentReachId != reachId) {
      _detachWatches();
      _currentReachId = reachId;
    }
  }

  /// Re-decode the current reach's cached entries in the (new) current unit.
  void _redecodeFromCache(String reachId) {
    for (final e in _sectionProducts.entries) {
      final entry = _repo.watch(_keyFor(reachId, e.value)).value;
      if (entry == null) continue;
      final decoded = NwmForecastPayload.decode(entry, _unitService);
      if (decoded == null) continue;
      _currentForecast = _currentForecast == null
          ? decoded
          : _mergeForecastData(_currentForecast!, decoded);
    }
  }

  ForecastResponse _mergeForecastData(
    ForecastResponse existing,
    ForecastResponse newData,
  ) {
    return ForecastResponse(
      // Keep the richer reach (return periods merge onto `existing`).
      reach: existing.reach.hasReturnPeriods ? existing.reach : newData.reach,
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

  void _checkAllComplete() {
    if (_hourlyState.isDone &&
        _dailyState.isDone &&
        _extendedState.isDone &&
        _returnPeriodsState.isDone) {
      _setLoadingPhase('complete');
    }
  }

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

  @override
  void dispose() {
    _detachWatches();
    super.dispose();
  }
}

/// Bridge for merging raw return-period rows onto an existing [ReachData],
/// through the ONE parser (`ReachDataDto.fromReturnPeriodApi`) — a second
/// regex-based implementation here would be exactly the duplication decision
/// 13 forbids.
class ReachDataDtoBridge {
  const ReachDataDtoBridge._();

  static ReachData mergeReturnPeriods(ReachData reach, List<dynamic> raw) =>
      reach.mergeWith(ReachDataDto.fromReturnPeriodApi(raw).toEntity());
}
