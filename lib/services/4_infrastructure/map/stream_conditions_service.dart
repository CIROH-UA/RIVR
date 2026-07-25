// lib/services/4_infrastructure/map/stream_conditions_service.dart

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Fetches pre-computed GEOGLOWS stream conditions — the above-normal reaches
/// for a VPU as `{station_id: floodCategory}` — from the conditions Cloud
/// Function. The backend derives these daily from each reach's forecast peak vs
/// its return periods; the map paints them via
/// [MapVectorTilesService.applyGeoglowsConditions].
class StreamConditionsService {
  final http.Client _client;

  StreamConditionsService({http.Client? client})
      : _client = client ?? http.Client();

  // The backend read (~1-3 GB from S3) can take up to ~90s on a cold instance;
  // the caller fetches this off the map's critical path, so a generous timeout
  // is fine.
  static const Duration _timeout = Duration(seconds: 120);

  /// Above-normal reaches for [vpu] as station-id -> category index (1..4).
  /// Best-effort: returns an empty map on any failure so the map simply stays
  /// uncolored rather than erroring.
  Future<Map<int, int>> fetchConditions(int vpu) async {
    final res = await _fetch(AppConfig.getGeoglowsConditionsUrl(vpu), 'VPU $vpu');
    return res?.conditions ?? const {};
  }

  /// Resolve the region from a reach the client can see and return its VPU +
  /// above-normal reaches. Lets the map color whatever's on screen without
  /// knowing VPU boundaries. Null on failure (best-effort).
  Future<({int vpu, Map<int, int> conditions})?> fetchByStation(
    int stationId,
  ) async {
    final res = await _fetch(
      AppConfig.getGeoglowsConditionsByStationUrl(stationId),
      'station $stationId',
    );
    if (res == null || res.vpu == null) return null;
    return (vpu: res.vpu!, conditions: res.conditions);
  }

  /// Above-normal reaches among [stationIds] (the NWM reaches currently on
  /// screen) as station-id -> category. Best-effort: empty on any failure.
  Future<Map<int, int>> fetchNwmByStations(Iterable<int> stationIds) async {
    if (stationIds.isEmpty) return const {};
    final res = await _fetch(
      AppConfig.getNwmConditionsUrl(stationIds),
      'NWM (${stationIds.length} reaches)',
    );
    return res?.conditions ?? const {};
  }

  Future<({int? vpu, Map<int, int> conditions})?> _fetch(
    String url,
    String label,
  ) async {
    try {
      final res = await _client.get(Uri.parse(url)).timeout(_timeout);
      if (res.statusCode != 200) {
        AppLogger.warning(
          'StreamConditions',
          '$label returned ${res.statusCode}: ${res.body}',
        );
        return null;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map || decoded['conditions'] is! Map) return null;

      final out = <int, int>{};
      (decoded['conditions'] as Map).forEach((k, v) {
        final id = int.tryParse(k.toString());
        final cat = v is int ? v : int.tryParse(v.toString());
        if (id != null && cat != null) out[id] = cat;
      });
      final vpu = decoded['vpu'];
      AppLogger.info(
        'StreamConditions',
        '$label: ${out.length} above-normal reaches (vpu ${decoded['vpu']})',
      );
      return (
        vpu: vpu is int ? vpu : int.tryParse('${vpu ?? ''}'),
        conditions: out,
      );
    } catch (e) {
      AppLogger.warning('StreamConditions', 'Fetch failed for $label: $e');
      return null;
    }
  }
}
