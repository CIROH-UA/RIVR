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
    final url = AppConfig.getGeoglowsConditionsUrl(vpu);
    try {
      final res =
          await _client.get(Uri.parse(url)).timeout(_timeout);
      if (res.statusCode != 200) {
        AppLogger.warning(
          'StreamConditions',
          'VPU $vpu returned ${res.statusCode}: ${res.body}',
        );
        return const {};
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map || decoded['conditions'] is! Map) return const {};

      final out = <int, int>{};
      (decoded['conditions'] as Map).forEach((k, v) {
        final id = int.tryParse(k.toString());
        final cat = v is int ? v : int.tryParse(v.toString());
        if (id != null && cat != null) out[id] = cat;
      });
      AppLogger.info(
        'StreamConditions',
        'VPU $vpu: ${out.length} above-normal reaches',
      );
      return out;
    } catch (e) {
      AppLogger.warning('StreamConditions', 'Fetch failed for VPU $vpu: $e');
      return const {};
    }
  }
}
