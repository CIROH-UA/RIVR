// lib/models/1_domain/shared/forecast_source.dart

/// Which data source / model a river reach's forecast comes from.
///
/// [nwm] = NOAA National Water Model (US only, short/medium/long range).
/// [geoglows] = GEOGLOWS v2 (global, non-US rivers; one 15-day ensemble).
///
/// The source is determined at selection time from which map tile layer the
/// tapped feature came from, then threaded through navigation so the forecast
/// flow calls the right API (NOAA vs GEOGLOWS) without guessing from the id.
enum ForecastSource {
  nwm,
  geoglows;

  /// Map tile layer ids belonging to the GEOGLOWS stream tileset are prefixed
  /// with this; anything else is treated as NWM.
  static const String geoglowsLayerPrefix = 'geoglows';

  /// Resolve the source from the Mapbox layer ids a tapped feature matched.
  /// Defaults to [nwm] when no GEOGLOWS layer is present.
  static ForecastSource fromLayerIds(Iterable<String?> layerIds) {
    for (final id in layerIds) {
      if (id != null && id.startsWith(geoglowsLayerPrefix)) {
        return ForecastSource.geoglows;
      }
    }
    return ForecastSource.nwm;
  }

  bool get isGeoglows => this == ForecastSource.geoglows;
  bool get isNwm => this == ForecastSource.nwm;

  /// Stable string for navigation args / logging.
  String get id => name;

  static ForecastSource fromId(String? value) {
    return ForecastSource.values.firstWhere(
      (s) => s.name == value,
      orElse: () => ForecastSource.nwm,
    );
  }
}
