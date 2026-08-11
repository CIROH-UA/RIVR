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

  // Must exceed the backend's own timeout, or the client gives up on requests
  // the server would still have answered.
  //
  // `geoglows_stream_conditions` is capped at `timeout_sec=180`, and the work
  // is linear in river count at roughly 950 rivers/s (measured). At 120s the
  // client abandoned anything over ~114,000 rivers — which is 14 of the 125
  // VPUs, about a third of the world's rivers, silently uncolorable no matter
  // how long the user waited. 200s gives the backend its full 180s plus
  // network overhead. Both callers fetch this off the map's critical path, so
  // a long ceiling costs nothing in responsiveness.
  //
  // This is a floor, not a fix: VPUs above ~171,000 rivers still cannot finish
  // inside the backend's own 180s. Precomputing removes the ceiling entirely
  // (ADR 0005).
  static const Duration _timeout = Duration(seconds: 200);

  /// Every above-normal reach on earth, from the daily precomputed file.
  ///
  /// This is the fast path and it replaces the whole per-region dance: no
  /// working out which VPU is on screen, no waiting on a computation, no cold
  /// start. It is a static file on a CDN, so it lands in well under a second
  /// instead of the 15-300s a live region fetch costs — and unlike the live
  /// path it covers the large regions that could never finish inside the
  /// backend's own timeout at all.
  ///
  /// Only elevated reaches are in the file (under 1% of rivers on a typical
  /// day), so it stays small. Returns empty if the file isn't published yet,
  /// which leaves the caller free to fall back to the per-region endpoint.
  Future<Map<int, int>> fetchGlobalConditions() async {
    final res = await _fetch(AppConfig.geoglowsConditionsLatestUrl, 'global');
    return res?.conditions ?? const {};
  }

  /// The same daily file, but kept grouped by region.
  ///
  /// One download still carries the whole world; the grouping exists because
  /// *painting* is what costs time. Handing Mapbox all 85k reaches at once
  /// takes 8-12s; one region takes ~3s and a hundred reaches take no
  /// measurable time at all. So the map paints the region under the viewport
  /// first and backfills the rest.
  ///
  /// Empty if the file predates grouping, in which case the caller should fall
  /// back to [fetchGlobalConditions].
  Future<Map<int, Map<int, int>>> fetchGlobalConditionsByRegion() async {
    try {
      final res = await _client
          .get(Uri.parse(AppConfig.geoglowsConditionsLatestUrl))
          .timeout(_timeout);
      if (res.statusCode != 200) return const {};
      final decoded = jsonDecode(res.body);
      if (decoded is! Map || decoded['by_vpu'] is! Map) return const {};

      final out = <int, Map<int, int>>{};
      (decoded['by_vpu'] as Map).forEach((vpuKey, reaches) {
        final vpu = int.tryParse(vpuKey.toString());
        if (vpu == null || reaches is! Map) return;
        final inner = <int, int>{};
        reaches.forEach((k, v) {
          final id = int.tryParse(k.toString());
          final cat = v is int ? v : int.tryParse(v.toString());
          if (id != null && cat != null) inner[id] = cat;
        });
        if (inner.isNotEmpty) out[vpu] = inner;
      });
      AppLogger.info(
        'StreamConditions',
        'global by region: ${out.length} regions, '
            '${out.values.fold<int>(0, (a, b) => a + b.length)} reaches',
      );
      return out;
    } catch (e) {
      AppLogger.warning('StreamConditions', 'Grouped fetch failed: $e');
      return const {};
    }
  }

  /// The daily precomputed US conditions, grouped by HUC6 basin.
  ///
  /// Same shape and same reasoning as [fetchGlobalConditionsByRegion]: one
  /// download, grouped so the map can paint the basin under the viewport first
  /// rather than handing Mapbox every reach at once.
  ///
  /// This replaces asking the backend to classify the ~800 reaches on screen
  /// every time the map settled. The horizon differs from the old path — NOAA's
  /// published product is the peak over the next five days, where the old one
  /// was an 18-hour short-range max — which also brings NWM into line with
  /// GEOGLOWS, already classified on peak-over-forecast.
  Future<Map<String, Map<int, int>>> fetchNwmConditionsByBasin() async {
    try {
      final res = await _client
          .get(Uri.parse(AppConfig.nwmConditionsLatestUrl))
          .timeout(_timeout);
      if (res.statusCode != 200) return const {};
      final decoded = jsonDecode(res.body);
      if (decoded is! Map || decoded['by_huc6'] is! Map) return const {};

      final out = <String, Map<int, int>>{};
      (decoded['by_huc6'] as Map).forEach((huc, reaches) {
        if (reaches is! Map) return;
        final inner = <int, int>{};
        reaches.forEach((k, v) {
          final id = int.tryParse(k.toString());
          final cat = v is int ? v : int.tryParse(v.toString());
          if (id != null && cat != null) inner[id] = cat;
        });
        if (inner.isNotEmpty) out[huc.toString()] = inner;
      });
      AppLogger.info(
        'StreamConditions',
        'NWM by basin: ${out.length} basins, '
            '${out.values.fold<int>(0, (a, b) => a + b.length)} reaches '
            '(${decoded['horizon']})',
      );
      return out;
    } catch (e) {
      AppLogger.warning('StreamConditions', 'NWM grouped fetch failed: $e');
      return const {};
    }
  }

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
