// lib/models/1_domain/shared/river_data/forecast_product.dart

/// A distinct, independently-cacheable unit of river data.
///
/// This is the third dimension of a cache key (alongside source + reachId): two
/// requests for the *same* reach but *different* products (e.g. NWM short-range
/// vs medium-range) are cached separately, while two requests for the same
/// product de-duplicate to one fetch.
///
/// Products are intentionally source-tagged where a source has a native shape
/// that does not (yet) map onto a shared taxonomy — GEOGLOWS' deterministic and
/// ensemble series are their own products until the unified domain model
/// (see ADR 0001, decision D7 / Step 7) collapses the NWM/GEOGLOWS fork. Adding
/// a new source adds its products here; nothing else in the key changes.
enum ForecastProduct {
  /// NWM analysis-assimilation — current conditions, hourly.
  analysisAssimilation,

  /// NWM short-range forecast (~18 h, hourly).
  shortRange,

  /// NWM medium-range forecast (~10 d, every 6 h).
  mediumRange,

  /// NWM long-range forecast (~30 d, every 6 h).
  longRange,

  /// NWM medium-range blend (~10 d, every 6 h).
  mediumRangeBlend,

  /// Return-period thresholds (currently NWM; native units, unit-independent).
  returnPeriods,

  /// GEOGLOWS deterministic 15-day forecast (median + uncertainty band).
  geoglowsForecast,

  /// GEOGLOWS ensemble statistics (min/25p/median/75p/max).
  geoglowsEnsemble;

  /// Stable string used in cache keys / storage and logging. Mirrors the
  /// [ForecastSource.id] pattern so keys are human-readable.
  String get id => name;

  /// Parse back from [id]; throws [ArgumentError] on an unknown value so a bad
  /// key surfaces loudly rather than silently mapping to the wrong product.
  static ForecastProduct fromId(String value) => ForecastProduct.values
      .firstWhere(
        (p) => p.name == value,
        orElse: () =>
            throw ArgumentError.value(value, 'value', 'Unknown ForecastProduct'),
      );
}
