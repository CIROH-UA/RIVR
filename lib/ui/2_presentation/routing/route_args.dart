// lib/ui/2_presentation/routing/route_args.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';

/// Typed argument for routes that only need a reach ID.
/// Used by: forecast, reach-overview, short/medium/long-range-detail,
/// image-selection.
///
/// [source] determines which forecast backend the reach belongs to (NWM vs
/// GEOGLOWS); defaults to NWM for the US-only callers that predate GEOGLOWS.
class ReachArgs {
  final String reachId;
  final ForecastSource source;
  const ReachArgs({required this.reachId, this.source = ForecastSource.nwm});
}

/// Typed argument for the hydrograph route.
class HydrographArgs {
  final String reachId;
  final String forecastType;
  final String? title;

  const HydrographArgs({
    required this.reachId,
    required this.forecastType,
    this.title,
  });
}
