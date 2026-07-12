// lib/services/4_infrastructure/river_data/geoglows_forecast_payload.dart

import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';

/// The one definition of the GEOGLOWS forecast cache schema. [encode] is used by
/// `GeoglowsDataSource` to store a fetched forecast; [decode] is used by the UI
/// consumers to rebuild it — converting flow values from the stored unit to the
/// user's current display unit (ADR 0001, D2: convert at read). Keeping both
/// halves here prevents the schema from drifting between producer and consumer.
class GeoglowsForecastPayload {
  const GeoglowsForecastPayload._();

  static Map<String, dynamic> encode(GeoglowsForecast fc) => {
    'riverId': fc.riverId,
    'generatedAt': fc.generatedAt.toIso8601String(),
    'points': [
      for (final p in fc.points)
        {
          't': p.validTime.toIso8601String(),
          'median': p.median,
          'lower': p.lower,
          'upper': p.upper,
        },
    ],
    // Recurrence year -> flow (stored in the fetch-time unit); keys as strings.
    'returnPeriods': fc.returnPeriods?.map((k, v) => MapEntry(k.toString(), v)),
  };

  static GeoglowsForecast decode(
    RiverDataEntry entry,
    IFlowUnitPreferenceService unitService,
  ) {
    final from = entry.unit;
    final to = unitService.currentFlowUnit;
    double conv(Object? v) =>
        unitService.convertFlow((v as num).toDouble(), from, to);

    final rawPoints = (entry.payload['points'] as List?) ?? const [];
    final points = [
      for (final p in rawPoints)
        GeoglowsForecastPoint(
          validTime: DateTime.parse((p as Map)['t'] as String),
          median: conv(p['median']),
          lower: conv(p['lower']),
          upper: conv(p['upper']),
        ),
    ];

    final rawRp = entry.payload['returnPeriods'] as Map?;
    final returnPeriods = rawRp == null
        ? null
        : {
            for (final e in rawRp.entries)
              int.parse(e.key as String): conv(e.value),
          };

    return GeoglowsForecast(
      riverId: entry.payload['riverId'] as String,
      unit: unitService.getDisplayUnit(),
      generatedAt: DateTime.parse(entry.payload['generatedAt'] as String),
      points: points,
      returnPeriods: returnPeriods,
    );
  }
}
