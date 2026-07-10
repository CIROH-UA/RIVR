// lib/services/4_infrastructure/river_data/geoglows_data_source.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/publish_schedule.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';

/// [IRiverDataSource] for GEOGLOWS (global, non-US rivers). A thin adapter over
/// the existing [IGeoglowsApiService] proxy client. GEOGLOWS publishes once a
/// day at 00Z, so a fetched forecast is valid until the next 00Z run.
class GeoglowsDataSource implements IRiverDataSource {
  GeoglowsDataSource({
    required IGeoglowsApiService api,
    required IFlowUnitPreferenceService unitService,
  }) : _api = api,
       _unitService = unitService;

  final IGeoglowsApiService _api;
  final IFlowUnitPreferenceService _unitService;

  /// Slack past 00Z: the proxy has a cold start and the run isn't instant.
  static const Duration _skew = Duration(minutes: 15);

  @override
  ForecastSource get source => ForecastSource.geoglows;

  @override
  Set<ForecastProduct> get supportedProducts => const {
    ForecastProduct.geoglowsForecast,
  };

  @override
  DateTime validUntil(ForecastProduct product, DateTime now) {
    switch (product) {
      case ForecastProduct.geoglowsForecast:
      case ForecastProduct.geoglowsEnsemble:
        return PublishSchedule.nextUtcMidnight(now).add(_skew);
      default:
        throw ArgumentError('GEOGLOWS does not support $product');
    }
  }

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    switch (key.product) {
      case ForecastProduct.geoglowsForecast:
        final forecast = await _api.fetchForecast(key.reachId);
        return SourceFetchResult(
          payload: GeoglowsForecastPayload.encode(forecast),
          // The API converted to the current unit; tag with the canonical token
          // (CFS/CMS) so read-time conversion knows what it holds.
          unit: _unitService.currentFlowUnit,
        );
      default:
        throw ArgumentError('GEOGLOWS does not support ${key.product}');
    }
  }
}
