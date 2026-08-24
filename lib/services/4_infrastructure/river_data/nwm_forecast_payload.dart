// lib/services/4_infrastructure/river_data/nwm_forecast_payload.dart

import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/3_datasources/shared/dtos/reach_data_dto.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Codec between a raw-NOAA `RiverDataEntry` and a [ForecastResponse]
/// (ADR 0011 Phase 3).
///
/// The NWM data source stores each series product's payload EXACTLY as the API
/// returned it (already converted to the unit preference in force at fetch
/// time, recorded in `entry.unit`). This decodes that payload and, when the
/// preference has changed since the fetch, converts every series to the
/// current unit — so a unit flip re-renders from the same cached bytes with
/// zero refetches (Phase 2 guard 6, made app-wide here).
class NwmForecastPayload {
  const NwmForecastPayload._();

  /// Decode an entry into a [ForecastResponse], converted to the reader's
  /// current unit. Null when the payload cannot be read — the caller treats
  /// that as "section unavailable", never as a crash (same rule as every
  /// narrow codec).
  static ForecastResponse? decode(
    RiverDataEntry entry,
    IFlowUnitPreferenceService unitService,
  ) {
    ForecastResponse response;
    try {
      response = ForecastResponseDto.fromApiResponse(entry.payload);
    } catch (e) {
      AppLogger.warning(
        'NwmForecastPayload',
        'Could not decode ${entry.key.storageKey}: $e',
      );
      return null;
    }

    final from = unitService.normalizeUnit(entry.unit);
    final to = unitService.normalizeUnit(unitService.currentFlowUnit);
    if (from == to) return response;

    ForecastSeries? convert(ForecastSeries? s) =>
        s?.convertToUnit(to, unitService);
    Map<String, ForecastSeries> convertMap(Map<String, ForecastSeries> m) =>
        m.map((k, v) => MapEntry(k, v.convertToUnit(to, unitService)));

    return ForecastResponse(
      reach: response.reach,
      analysisAssimilation: convert(response.analysisAssimilation),
      shortRange: convert(response.shortRange),
      mediumRange: convertMap(response.mediumRange),
      longRange: convertMap(response.longRange),
      mediumRangeBlend: convert(response.mediumRangeBlend),
    );
  }
}
