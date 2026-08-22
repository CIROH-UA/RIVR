// lib/services/4_infrastructure/river_data/narrow_nwm_payloads.dart

import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/3_datasources/shared/dtos/reach_data_dto.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Read-side codecs for the two narrow NWM products the map detail sheet reads
/// instead of the bundled `reachSummary` (ADR 0011 Phase 1).
///
/// Both **delegate** their derivation rather than reimplementing it — current
/// flow through `IForecastService.getCurrentFlow`, thresholds through
/// `ReachDataDto.fromReturnPeriodApi`. That is deliberate: ADR 0011 decision 15
/// says a derived value is computed in exactly one place, and a second
/// "extract the current flow" implementation living in a codec is precisely the
/// drift ADR 0002 exists to prevent.
///
/// The stored payloads keep the raw upstream shape. Parsing on read rather than
/// on write keeps the cache contract unchanged for anything already holding
/// these entries.
class CurrentFlowPayload {
  const CurrentFlowPayload._();

  /// Current flow from an `analysisAssimilation` entry, converted from the unit
  /// it was stored in to the user's current preference.
  static double? decode(
    RiverDataEntry entry,
    IForecastService forecastService,
    IFlowUnitPreferenceService unitService,
  ) {
    // `fromApiResponse` throws on a payload it cannot read — an empty body, a
    // truncated response, a shape change upstream. A codec must degrade to "no
    // value" rather than take the whole sheet down with it: the caller treats
    // null as "flow unavailable" and still renders the river's name.
    double? flow;
    try {
      final response = ForecastResponseDto.fromApiResponse(entry.payload);
      flow = forecastService.getCurrentFlow(response);
    } catch (e) {
      // Logged, not swallowed: a decode bug and "upstream had no data" look
      // identical on screen, and review found exactly that hiding in a test
      // fixture. Without this line nothing would ever notice.
      AppLogger.warning(
        'CurrentFlowPayload',
        'Could not decode current flow for ${entry.key.storageKey}: $e',
      );
      return null;
    }
    if (flow == null) return null;

    final to = unitService.currentFlowUnit;
    if (entry.unit == to) return flow;
    return unitService.convertFlow(flow, entry.unit, to);
  }
}

/// Return-period thresholds (return year -> flow).
class ReturnPeriodPayload {
  const ReturnPeriodPayload._();

  /// Thresholds from a `returnPeriods` entry.
  ///
  /// The upstream API serves these in **native units (CMS)** regardless of what
  /// the forecast values were converted to, so they are converted from CMS —
  /// not from `entry.unit`, which records the user's preference at fetch time
  /// and is not what these numbers are in. Getting this backwards silently
  /// misclassifies every flood category, which is why it is spelled out.
  static Map<int, double>? decode(
    RiverDataEntry entry,
    IFlowUnitPreferenceService unitService,
  ) {
    final raw = entry.payload['returnPeriods'];
    if (raw is! List || raw.isEmpty) return null;

    // Same reasoning as above: a shape it cannot read means "no thresholds",
    // which costs the flood category and nothing else.
    Map<int, double>? native;
    try {
      native = ReachDataDto.fromReturnPeriodApi(raw).toEntity().returnPeriods;
    } catch (e) {
      AppLogger.warning(
        'ReturnPeriodPayload',
        'Could not decode return periods for ${entry.key.storageKey}: $e',
      );
      return null;
    }
    if (native == null || native.isEmpty) return null;

    final to = unitService.currentFlowUnit;
    if (to == 'CMS') return native;
    return native.map(
      (year, flow) => MapEntry(year, unitService.convertFlow(flow, 'CMS', to)),
    );
  }
}
