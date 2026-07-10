// lib/services/4_infrastructure/river_data/nwm_data_source.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/publish_schedule.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';

/// [IRiverDataSource] for the NOAA National Water Model (US). A thin adapter
/// over the existing [INoaaApiService]: it maps [ForecastProduct]s to NWM API
/// calls and declares NWM's publish cadence. Payloads are tagged with the unit
/// they were fetched in (the repository converts at read).
class NwmDataSource implements IRiverDataSource {
  NwmDataSource({
    required INoaaApiService api,
    required IFlowUnitPreferenceService unitService,
  }) : _api = api,
       _unitService = unitService;

  final INoaaApiService _api;
  final IFlowUnitPreferenceService _unitService;

  /// Small slack so we don't invalidate the instant a cycle rolls over and
  /// refetch before the new run has actually published.
  static const Duration _skew = Duration(minutes: 5);

  @override
  ForecastSource get source => ForecastSource.nwm;

  @override
  Set<ForecastProduct> get supportedProducts => const {
    ForecastProduct.analysisAssimilation,
    ForecastProduct.shortRange,
    ForecastProduct.mediumRange,
    ForecastProduct.longRange,
    ForecastProduct.returnPeriods,
  };

  @override
  DateTime validUntil(ForecastProduct product, DateTime now) {
    switch (product) {
      case ForecastProduct.analysisAssimilation:
      case ForecastProduct.shortRange:
        // Hourly.
        return PublishSchedule.nextTopOfHour(now).add(_skew);
      case ForecastProduct.mediumRange:
      case ForecastProduct.longRange:
        // Every 6 hours (00/06/12/18Z).
        return PublishSchedule.nextCycle(now, everyHours: 6).add(_skew);
      case ForecastProduct.returnPeriods:
        // Static thresholds — effectively don't change day to day.
        return now.toUtc().add(const Duration(days: 30));
      case ForecastProduct.mediumRangeBlend:
      case ForecastProduct.geoglowsForecast:
      case ForecastProduct.geoglowsEnsemble:
        throw ArgumentError('NWM does not support $product');
    }
  }

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    final unit = _unitService.currentFlowUnit;
    switch (key.product) {
      case ForecastProduct.analysisAssimilation:
        return SourceFetchResult(
          payload: await _api.fetchCurrentFlowOnly(key.reachId),
          unit: unit,
        );
      case ForecastProduct.shortRange:
        return SourceFetchResult(
          payload: await _api.fetchForecast(key.reachId, 'short_range'),
          unit: unit,
        );
      case ForecastProduct.mediumRange:
        return SourceFetchResult(
          payload: await _api.fetchForecast(key.reachId, 'medium_range'),
          unit: unit,
        );
      case ForecastProduct.longRange:
        return SourceFetchResult(
          payload: await _api.fetchForecast(key.reachId, 'long_range'),
          unit: unit,
        );
      case ForecastProduct.returnPeriods:
        return SourceFetchResult(
          payload: {'returnPeriods': await _api.fetchReturnPeriods(key.reachId)},
          unit: unit,
        );
      case ForecastProduct.mediumRangeBlend:
      case ForecastProduct.geoglowsForecast:
      case ForecastProduct.geoglowsEnsemble:
        throw ArgumentError('NWM does not support ${key.product}');
    }
  }
}
