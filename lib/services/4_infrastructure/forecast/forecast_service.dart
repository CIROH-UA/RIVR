// lib/services/4_infrastructure/forecast/forecast_service.dart

import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/3_datasources/shared/dtos/reach_data_dto.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// What is left of the old 1,000-line forecast loader after ADR 0011 Phase 3.
///
/// Everything else moved or died: the phased load methods (`loadOverviewData`,
/// `loadCompleteReachData`, ...) lost their only client when
/// `ReachDataProvider` was rewired onto `IRiverDataRepository`; the bundle
/// (`loadReachDetailsData` / the `reachSummary` product) was deleted with its
/// last reader; the value helpers are pure functions in `ForecastValues`; the
/// three TTL caches and the legacy forecast disk cache are gone — the ONE
/// cache is `RiverDataCache`.
///
/// The survivor backs `NwmDataSource`'s `reachMetadata` product: the cheapest
/// possible "who is this reach" fetch, with the reach-info cache in front of
/// it.
class ForecastService implements IForecastService {
  final INoaaApiService _apiService;
  final IReachCacheService _cacheService;

  ForecastService({
    required INoaaApiService apiService,
    required IReachCacheService cacheService,
  })  : _apiService = apiService,
        _cacheService = cacheService;

  /// Basic reach info only (coordinates + name) — no flow, no series, no
  /// geocoding.
  @override
  Future<ReachData> loadBasicReachInfo(String reachId) async {
    try {
      final cachedReach = await _cacheService.get(reachId);
      if (cachedReach != null) return cachedReach;

      final reachInfo = await _apiService.fetchReachInfo(reachId);
      final reach = ReachDataDto.fromNoaaApi(reachInfo).toEntity();
      await _cacheService.store(reach);
      return reach;
    } catch (e) {
      AppLogger.error('ForecastService', 'Error loading basic reach info', e);
      rethrow;
    }
  }
}
