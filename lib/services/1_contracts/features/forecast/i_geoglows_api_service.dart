// lib/services/1_contracts/features/forecast/i_geoglows_api_service.dart

import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';

/// Interface for fetching GEOGLOWS forecasts (global, non-US rivers).
///
/// All returned flow values are already converted to the user's preferred unit
/// by the implementation; callers do not need to convert from native m³/s.
abstract class IGeoglowsApiService {
  /// 15-day deterministic forecast (median + uncertainty band) for [riverId]
  /// (the GEOGLOWS LINKNO).
  Future<GeoglowsForecast> fetchForecast(String riverId);

  /// Ensemble-statistics forecast (min/25p/median/75p/max) for [riverId] — the
  /// data behind the uncertainty-fan hero.
  Future<GeoglowsEnsembleForecast> fetchEnsembleStats(String riverId);
}
