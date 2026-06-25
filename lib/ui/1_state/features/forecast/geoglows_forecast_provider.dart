// lib/ui/1_state/features/forecast/geoglows_forecast_provider.dart

import 'package:flutter/foundation.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

/// State for the GEOGLOWS forecast path (global, non-US rivers).
///
/// Deliberately separate from [ReachDataProvider]: GEOGLOWS is a different data
/// shape (one 15-day ensemble vs the NWM's short/medium/long products), so it
/// gets its own provider + page rather than being forced into the NWM model.
class GeoglowsForecastProvider extends ChangeNotifier {
  final IGeoglowsApiService _api;

  GeoglowsForecastProvider(this._api);

  bool _isLoading = false;
  String? _error;
  GeoglowsForecast? _forecast;

  bool get isLoading => _isLoading;
  String? get error => _error;
  GeoglowsForecast? get forecast => _forecast;
  bool get hasData => _forecast != null && _forecast!.points.isNotEmpty;

  /// Load the deterministic forecast (median + uncertainty) for [riverId].
  Future<void> load(String riverId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _forecast = await _api.fetchForecast(riverId);
    } catch (e) {
      _error = e is ServiceException ? e.message : e.toString();
      _forecast = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
