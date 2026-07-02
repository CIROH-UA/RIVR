// lib/services/4_infrastructure/api/geoglows_api_service.dart

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/models/1_domain/features/forecast/geoglows_forecast.dart';

/// Fetches GEOGLOWS forecasts for global (non-US) rivers.
///
/// GEOGLOWS serves flow natively in m³/s (CMS). This service converts every
/// value to the user's preferred unit at the API boundary, mirroring how
/// [NoaaApiService] handles the NWM — so the rest of the app stays unit-agnostic.
class GeoglowsApiService implements IGeoglowsApiService {
  final http.Client _client;
  final IFlowUnitPreferenceService _unitService;

  GeoglowsApiService({
    http.Client? client,
    required IFlowUnitPreferenceService unitService,
  })  : _client = client ?? http.Client(),
        _unitService = unitService;

  static const Duration _timeout = Duration(seconds: 30);
  static const _headers = {
    'Content-Type': 'application/json',
    'User-Agent': 'RIVR/1.0',
  };

  /// GEOGLOWS delivers flow natively in cubic meters per second.
  static const String _nativeUnit = 'CMS';

  @override
  Future<GeoglowsForecast> fetchForecast(String riverId) async {
    final url = AppConfig.getGeoglowsProxyUrl(riverId);
    AppLogger.debug('GEOGLOWS_API', 'Fetching forecast for river $riverId');

    try {
      final data = await _getJson(url, riverId);
      final fc = (data['forecast'] as Map?) ?? const {};

      final times = _asList(fc['datetime']);
      final median = _asList(fc['flow_median']);
      final lower = _asList(fc['flow_uncertainty_lower']);
      final upper = _asList(fc['flow_uncertainty_upper']);

      if (times.isEmpty || median.isEmpty) {
        throw ServiceException.notFound(
          'No GEOGLOWS forecast available for this river.',
          detail: 'river_id=$riverId returned empty forecast arrays',
        );
      }

      final points = <GeoglowsForecastPoint>[];
      for (var i = 0; i < times.length; i++) {
        final t = _parseTime(times[i]);
        final m = _parseFlow(_at(median, i));
        if (t == null || m == null) continue; // skip gaps
        points.add(
          GeoglowsForecastPoint(
            validTime: t,
            median: m,
            lower: _parseFlow(_at(lower, i)) ?? m,
            upper: _parseFlow(_at(upper, i)) ?? m,
          ),
        );
      }

      AppLogger.info(
        'GEOGLOWS_API',
        'Forecast for $riverId: ${points.length} points -> ${_unitService.currentFlowUnit}',
      );

      return GeoglowsForecast(
        riverId: riverId,
        unit: _unitService.getDisplayUnit(),
        generatedAt: _generatedAt(data),
        points: points,
      );
    } catch (e) {
      AppLogger.error('GEOGLOWS_API', 'Error fetching forecast for $riverId', e);
      throw ServiceException.fromError(e, context: 'GeoglowsApiService.fetchForecast');
    }
  }

  @override
  Future<GeoglowsEnsembleForecast> fetchEnsembleStats(String riverId) async {
    final url = AppConfig.getGeoglowsProxyUrl(riverId);
    AppLogger.debug('GEOGLOWS_API', 'Fetching ensemble stats for river $riverId');

    try {
      final data = await _getJson(url, riverId);
      final es = (data['ensemble'] as Map?) ?? const {};

      final times = _asList(es['datetime']);
      final min = _asList(es['flow_min']);
      final p25 = _asList(es['flow_25p']);
      final med = _asList(es['flow_med']);
      final p75 = _asList(es['flow_75p']);
      final max = _asList(es['flow_max']);
      final avg = _asList(es['flow_avg']);

      if (times.isEmpty || med.isEmpty) {
        throw ServiceException.notFound(
          'No GEOGLOWS ensemble forecast available for this river.',
          detail: 'river_id=$riverId returned empty ensemble arrays',
        );
      }

      // The ensemble runs at a coarser cadence than the hourly time axis, so
      // intermediate steps come back as empty strings — keep only real points.
      final points = <GeoglowsEnsemblePoint>[];
      for (var i = 0; i < times.length; i++) {
        final t = _parseTime(times[i]);
        final m = _parseFlow(_at(med, i));
        if (t == null || m == null) continue;
        points.add(
          GeoglowsEnsemblePoint(
            validTime: t,
            min: _parseFlow(_at(min, i)) ?? m,
            p25: _parseFlow(_at(p25, i)) ?? m,
            median: m,
            p75: _parseFlow(_at(p75, i)) ?? m,
            max: _parseFlow(_at(max, i)) ?? m,
            mean: _parseFlow(_at(avg, i)) ?? m,
          ),
        );
      }

      AppLogger.info(
        'GEOGLOWS_API',
        'Ensemble for $riverId: ${points.length} points -> ${_unitService.currentFlowUnit}',
      );

      return GeoglowsEnsembleForecast(
        riverId: riverId,
        unit: _unitService.getDisplayUnit(),
        generatedAt: _generatedAt(data),
        points: points,
      );
    } catch (e) {
      AppLogger.error('GEOGLOWS_API', 'Error fetching ensemble stats for $riverId', e);
      throw ServiceException.fromError(e, context: 'GeoglowsApiService.fetchEnsembleStats');
    }
  }

  // --- helpers --------------------------------------------------------------

  /// GET + decode JSON, surfacing GEOGLOWS's `{"error": "..."}` bodies (which
  /// arrive with HTTP 200) as proper failures.
  Future<Map<String, dynamic>> _getJson(String url, String riverId) async {
    final response = await _client
        .get(Uri.parse(url), headers: _headers)
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw ServiceException.network(
        'GEOGLOWS API error: ${response.statusCode}',
        detail: 'river_id=$riverId, body=${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw ServiceException.unknown(
        'Unexpected GEOGLOWS response shape.',
        detail: 'river_id=$riverId',
      );
    }
    if (decoded.containsKey('error')) {
      throw ServiceException.network(
        'GEOGLOWS API returned an error.',
        detail: 'river_id=$riverId: ${decoded['error']}',
      );
    }
    return decoded;
  }

  List<dynamic> _asList(dynamic v) => v is List ? v : const [];

  dynamic _at(List<dynamic> list, int i) => i < list.length ? list[i] : null;

  DateTime? _parseTime(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v);
  }

  /// Parse a GEOGLOWS flow value (num, numeric string, or '' gap) and convert
  /// from native m³/s to the user's preferred unit. Returns null for gaps.
  double? _parseFlow(dynamic v) {
    double? raw;
    if (v is num) {
      raw = v.toDouble();
    } else if (v is String && v.isNotEmpty) {
      raw = double.tryParse(v);
    }
    if (raw == null) return null;
    return _unitService.convertToPreferredUnit(raw, _nativeUnit);
  }

  DateTime _generatedAt(Map<String, dynamic> data) {
    // Proxy shape: forecast_date is YYYYMMDD (the daily UTC model run).
    final fd = data['forecast_date'];
    if (fd is String && fd.length == 8) {
      final y = int.tryParse(fd.substring(0, 4));
      final mo = int.tryParse(fd.substring(4, 6));
      final d = int.tryParse(fd.substring(6, 8));
      if (y != null && mo != null && d != null) return DateTime.utc(y, mo, d);
    }
    // REST shape fallback: metadata.gen_date.
    final meta = data['metadata'];
    if (meta is Map && meta['gen_date'] is String) {
      final parsed = DateTime.tryParse(meta['gen_date'] as String);
      if (parsed != null) return parsed;
    }
    // Last resort: the first forecast timestamp.
    final fc = (data['forecast'] as Map?) ?? data;
    final first = _parseTime(_at(_asList(fc['datetime']), 0));
    return first ?? DateTime.now().toUtc();
  }
}
