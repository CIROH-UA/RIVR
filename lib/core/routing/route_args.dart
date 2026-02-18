// lib/core/routing/route_args.dart

/// Typed argument for routes that only need a reach ID.
/// Used by: forecast, reach-overview, short/medium/long-range-detail,
/// image-selection.
class ReachArgs {
  final String reachId;
  const ReachArgs({required this.reachId});
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
