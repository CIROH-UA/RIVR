// lib/models/1_domain/features/forecast/geoglows_forecast.dart

// Domain models for GEOGLOWS forecasts (global river coverage outside the US).
//
// GEOGLOWS is a different product shape than the NWM: a single 15-day forecast
// driven by a 51-member ensemble, delivered natively in m³/s. To keep the rest
// of the app unit-agnostic, all flow values in these models are already in the
// user's preferred unit (CFS or CMS) — the GEOGLOWS API layer converts from the
// native m³/s before constructing them.

/// A single timestep of the GEOGLOWS deterministic forecast.
class GeoglowsForecastPoint {
  /// Valid time of this forecast step.
  final DateTime validTime;

  /// Median (deterministic) flow, in the user's preferred unit.
  final double median;

  /// Lower bound of the uncertainty band, in the user's preferred unit.
  final double lower;

  /// Upper bound of the uncertainty band, in the user's preferred unit.
  final double upper;

  const GeoglowsForecastPoint({
    required this.validTime,
    required this.median,
    required this.lower,
    required this.upper,
  });
}

/// GEOGLOWS 15-day deterministic forecast for a single river.
///
/// [riverId] is the GEOGLOWS LINKNO — the same id the map tiles expose as
/// `station_id`, so a tapped reach maps directly to this forecast.
class GeoglowsForecast {
  final String riverId;

  /// Display unit label for the flow values, e.g. 'ft³/s' or 'm³/s'.
  final String unit;

  /// When the forecast was generated (model run time).
  final DateTime generatedAt;

  /// Ordered forecast steps (earliest first).
  final List<GeoglowsForecastPoint> points;

  const GeoglowsForecast({
    required this.riverId,
    required this.unit,
    required this.generatedAt,
    required this.points,
  });

  DateTime? get start => points.isEmpty ? null : points.first.validTime;
  DateTime? get end => points.isEmpty ? null : points.last.validTime;

  /// The nearest-term median flow — what a glance ("flowing at X now") shows.
  double? get currentMedian => points.isEmpty ? null : points.first.median;
}

/// A single timestep of the GEOGLOWS ensemble summary — the data behind the
/// uncertainty-fan hero (min / 25th / median / 75th / max).
class GeoglowsEnsemblePoint {
  final DateTime validTime;
  final double min;
  final double p25;
  final double median;
  final double p75;
  final double max;
  final double mean;

  const GeoglowsEnsemblePoint({
    required this.validTime,
    required this.min,
    required this.p25,
    required this.median,
    required this.p75,
    required this.max,
    required this.mean,
  });
}

/// GEOGLOWS ensemble-statistics forecast (the 51-member spread summarized as
/// percentile bands). Flow values are in the user's preferred unit.
class GeoglowsEnsembleForecast {
  final String riverId;
  final String unit;
  final DateTime generatedAt;
  final List<GeoglowsEnsemblePoint> points;

  const GeoglowsEnsembleForecast({
    required this.riverId,
    required this.unit,
    required this.generatedAt,
    required this.points,
  });

  DateTime? get start => points.isEmpty ? null : points.first.validTime;
  DateTime? get end => points.isEmpty ? null : points.last.validTime;
}
