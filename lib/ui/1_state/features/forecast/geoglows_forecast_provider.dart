// lib/ui/1_state/features/forecast/geoglows_forecast_provider.dart

import 'package:flutter/foundation.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';

/// State for the GEOGLOWS forecast path (global, non-US rivers).
///
/// Deliberately separate from [ReachDataProvider]: GEOGLOWS is a different data
/// shape (one 15-day ensemble vs the NWM's short/medium/long products), so it
/// gets its own provider + page rather than being forced into the NWM model.
///
/// Reads through the shared [IRiverDataRepository] (ADR 0001) rather than the
/// GEOGLOWS API directly, so a forecast fetched for the map bottom sheet is
/// reused here instead of re-fetched (fixes the tap → "See forecast" double
/// request). Flow values are converted from the cached unit to the user's unit
/// at read.
class GeoglowsForecastProvider extends ChangeNotifier {
  final IRiverDataRepository _repository;
  final IFlowUnitPreferenceService _unitService;

  GeoglowsForecastProvider(this._repository, this._unitService);

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
      final entry = await _repository.read(
        RiverDataKey(
          source: ForecastSource.geoglows,
          reachId: riverId,
          product: ForecastProduct.geoglowsForecast,
        ),
      );
      _forecast = entry == null
          ? null
          : GeoglowsForecastPayload.decode(entry, _unitService);
      if (_forecast == null) {
        _error = 'No GEOGLOWS forecast available for this river.';
      }
    } catch (e) {
      _error = e is ServiceException ? e.message : e.toString();
      _forecast = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
