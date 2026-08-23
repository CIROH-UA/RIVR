// lib/services/4_infrastructure/river_data/nwm_data_source.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/publish_schedule.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/reach_metadata_payload.dart';
import 'package:rivr/services/4_infrastructure/river_data/reach_summary_payload.dart';

/// [IRiverDataSource] for the NOAA National Water Model (US). A thin adapter
/// over the existing NWM stack: raw forecast products map to [INoaaApiService]
/// calls, while the composite `reachSummary` (current flow + name + category)
/// delegates to [IForecastService] to reuse its phased loading + classification
/// rather than re-deriving it. Payloads are tagged with the unit they were
/// fetched in (the repository converts at read).
class NwmDataSource implements IRiverDataSource {
  NwmDataSource({
    required INoaaApiService api,
    required IForecastService forecastService,
    required IFlowUnitPreferenceService unitService,
    required IGeocodingService geocoder,
  }) : _api = api,
       _forecastService = forecastService,
       _unitService = unitService,
       // Injected but deliberately UNUSED: `reachMetadata` must not geocode.
       // Holding the dependency is what makes that testable — a fake can
       // assert zero calls. The previous guard timed the fetch instead, and
       // review measured a real geocode returning in 86 ms, under the
       // threshold, so it could never have failed for the right reason.
       // ignore: unused_field
       _geocoder = geocoder;

  final INoaaApiService _api;
  final IForecastService _forecastService;
  final IFlowUnitPreferenceService _unitService;
  // ignore: unused_field
  final IGeocodingService _geocoder;

  /// Small slack so we don't invalidate the instant a cycle rolls over and
  /// refetch before the new run has actually published.
  static const Duration _skew = Duration(minutes: 5);

  @override
  ForecastSource get source => ForecastSource.nwm;

  @override
  Set<ForecastProduct> get supportedProducts => const {
    ForecastProduct.analysisAssimilation,
    ForecastProduct.reachSummary,
    ForecastProduct.reachMetadata,
    ForecastProduct.shortRange,
    ForecastProduct.mediumRange,
    ForecastProduct.longRange,
    ForecastProduct.returnPeriods,
  };

  @override
  DateTime validUntil(ForecastProduct product, DateTime now) {
    switch (product) {
      case ForecastProduct.analysisAssimilation:
      case ForecastProduct.reachSummary:
      case ForecastProduct.shortRange:
        // Hourly (driven by current flow).
        return PublishSchedule.nextTopOfHour(now).add(_skew);
      case ForecastProduct.mediumRange:
      case ForecastProduct.longRange:
        // Every 6 hours (00/06/12/18Z).
        return PublishSchedule.nextCycle(now, everyHours: 6).add(_skew);
      case ForecastProduct.returnPeriods:
      case ForecastProduct.reachMetadata:
        // Static — thresholds don't change day to day, and a river's name and
        // coordinates don't change at all.
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
      case ForecastProduct.reachSummary:
        // Reuse ForecastService's phased load + classification.
        final details = await _forecastService.loadReachDetailsData(
          key.reachId,
        );
        return SourceFetchResult(
          payload: ReachSummaryPayload.encode(details),
          unit: unit,
        );
      case ForecastProduct.reachMetadata:
        // The cheap half of the old reachSummary: no flow data, no forecast
        // series. Lets a surface title itself in isolation.
        // Deliberately does NOT geocode. An earlier version did, to preserve
        // the place name that `loadOverviewData` used to fill — but
        // `GeocodingService.reverseGeocode` catches internally and returns a
        // null map rather than throwing, so nothing bounded it except a 30 s
        // HTTP timeout. That put a second, unbounded network hop in front of
        // the one call this product exists to keep fast.
        //
        // The place name is decoration and is filled off the critical path by
        // the consumer (ADR 0011, geocoding off the critical path). `formattedLocation` here is
        // whatever the reach already knew.
        final reach = await _forecastService.loadBasicReachInfo(key.reachId);

        return SourceFetchResult(
          payload: ReachMetadataPayload.encode(
            ReachMetadata(
              riverName: reach.riverName,
              formattedLocation: reach.formattedLocation,
              latitude: reach.latitude,
              longitude: reach.longitude,
            ),
          ),
          // Nothing here is a flow value, so the stored unit is irrelevant —
          // recorded only to satisfy the entry contract.
          unit: unit,
        );
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
