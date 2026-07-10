// lib/services/4_infrastructure/river_data/reach_summary_payload.dart

import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';

/// The one definition of the NWM `reachSummary` cache schema — the map
/// bottom-sheet / favorites preview (current flow + name + flood category).
///
/// [encode] is used by `NwmDataSource` (which delegates to ForecastService to
/// build the [ReachDetailsData]); [decode] is used by the consumers, converting
/// the current-flow value from the stored unit to the user's current unit
/// (ADR 0001, D2). The flood [flowCategory] is unit-independent (a label derived
/// from comparing flow to return-period thresholds), so it is stored as-is.
class ReachSummaryPayload {
  const ReachSummaryPayload._();

  static Map<String, dynamic> encode(ReachDetailsData d) => {
    'riverName': d.riverName,
    'formattedLocation': d.formattedLocation,
    'currentFlow': d.currentFlow,
    'flowCategory': d.flowCategory,
    'latitude': d.latitude,
    'longitude': d.longitude,
    'isClassificationAvailable': d.isClassificationAvailable,
    // Return-period years -> flow; keys as strings for JSON. Stored raw (native
    // units) — consumers convert them themselves alongside the flow.
    'returnPeriods': d.returnPeriods?.map((k, v) => MapEntry(k.toString(), v)),
  };

  static ReachDetailsData decode(
    RiverDataEntry entry,
    IFlowUnitPreferenceService unitService,
  ) {
    final payload = entry.payload;
    final rawFlow = payload['currentFlow'] as num?;
    final currentFlow = rawFlow == null
        ? null
        : unitService.convertFlow(
            rawFlow.toDouble(),
            entry.unit,
            unitService.currentFlowUnit,
          );

    final rawPeriods = payload['returnPeriods'] as Map?;
    final returnPeriods = rawPeriods == null
        ? null
        : {
            for (final entry in rawPeriods.entries)
              int.parse(entry.key as String): (entry.value as num).toDouble(),
          };

    return ReachDetailsData(
      riverName: payload['riverName'] as String?,
      formattedLocation: payload['formattedLocation'] as String?,
      currentFlow: currentFlow,
      flowCategory: payload['flowCategory'] as String?,
      latitude: (payload['latitude'] as num?)?.toDouble(),
      longitude: (payload['longitude'] as num?)?.toDouble(),
      isClassificationAvailable:
          payload['isClassificationAvailable'] as bool? ?? false,
      returnPeriods: returnPeriods,
    );
  }
}
