// lib/services/4_infrastructure/map/map_vector_tiles_service.dart

import 'dart:convert';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/map/us_boundary_mask.dart';

/// Draws the NWM and GEOGLOWS stream networks from their vector tilesets.
///
/// **Deliberately unstyled.** This is a clean slate (2026-08-17). Everything
/// that used to live here — three stream-order layers per network, the
/// zoom-interpolated width tables, the inverse-zoom emphasis curve, per-band
/// opacity, the dimming pass and the nine flood-condition highlight layers —
/// has been removed so styling can be designed fresh.
///
/// Most of it existed to compensate for tilesets that could not thin
/// themselves: the old `nwm-channels` carried ~75% order-1/2 headwater creeks
/// at *every* zoom, so the app had to hide them. The `-v2` tilesets apply a
/// stream-order ladder at build time (order ≥8 at z0-3 up to everything at
/// z10-12), so that work is done before the tiles reach the device. See
/// `docs/adr/0005-colored-stream-latency.md`.
///
/// What remains is the minimum to render and query the networks:
/// one layer per network, one colour, one width expression driven by
/// `streamOrder`, and the per-network visibility toggles.
class MapVectorTilesService {
  MapboxMap? _mapboxMap;
  bool _isLoaded = false;

  /// The one colour every stream draws in. Shared by both networks on purpose:
  /// source is surfaced on tap and in the Stream Data sheet, not by hue.
  static const int _streamColor = 0xFF191970; // Midnight blue

  static const double _lineOpacity = 0.85;

  /// Layer ids. The `geoglows` prefix matters — tap source-routing keys off it
  /// (see `ForecastSource.fromLayerIds`).
  static const String nwmLayerId = 'nwm-streams';
  static const String geoglowsLayerId = 'geoglows-streams';
  static const String geoglowsUsLayerId = 'geoglows-us-streams';
  static const String floodLayerId = 'flooded-streams';

  /// Every layer this service owns, in draw order — flood last, on top.
  static const List<String> allLayerIds = [
    nwmLayerId,
    geoglowsLayerId,
    geoglowsUsLayerId,
    floodLayerId,
  ];

  /// The validated 5-band flood palette (ADR 0005). `cat` 1-4; anything not in
  /// the flood tileset is Normal by definition and simply isn't drawn here.
  static const int _catAction = 0xFFFFC400;
  static const int _catModerate = 0xFFFF8C00;
  static const int _catMajor = 0xFFE53935;
  static const int _catExtreme = 0xFF8E24AA;

  /// Colour straight from the tile — no runtime `match` over tens of thousands
  /// of ids, which is the whole reason the tileset is pre-coloured.
  static List<Object> _floodColorExpression() => [
    'match',
    ['get', 'cat'],
    1, _hex(_catAction),
    2, _hex(_catModerate),
    3, _hex(_catMajor),
    4, _hex(_catExtreme),
    _hex(_streamColor),
  ];

  /// Deliberately wider than the base network. Two reasons: the flood geometry
  /// is simplified to 10 m in the index (phase 4a) so it does not trace the
  /// base line exactly, and drawing it wider on top hides that divergence.
  ///
  /// Keyed on zoom, not stream order — the flood tileset carries only
  /// `station_id` and `cat`. Widest when zoomed out, where an elevated reach is
  /// acting as a symbol ("flooding here") rather than as geometry.
  static List<Object> _floodWidthExpression() => [
    'interpolate',
    ['linear'],
    ['zoom'],
    0, 2.5,
    5, 3.0,
    10, 3.5,
    14, 4.0,
  ];

  static String _hex(int argb) =>
      '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// Width straight from the reach's Strahler order — a headwater creek is a
  /// hairline, a continental river is heavy. No zoom term: the tilesets already
  /// decide which orders exist at a given zoom, so width only has to express
  /// how big the stream is, not how far away the camera is.
  static List<Object> _widthExpression() => [
    'interpolate',
    ['linear'],
    ['get', 'streamOrder'],
    1,
    0.5,
    4,
    1.2,
    7,
    2.5,
    10,
    5.0,
  ];

  // Per-network desired visibility. Default: NWM plus GEOGLOWS outside the US;
  // GEOGLOWS inside the US off, because it would double-draw over NWM.
  bool _nwmVisible = true;
  bool _geoglowsWorldVisible = true;
  bool _geoglowsUsVisible = false;

  /// GEOGLOWS defers to NWM inside the US: this simplified US boundary
  /// (CONUS + Alaska + Hawaii, see [kUsBoundaryGeoJson]) splits the single
  /// GEOGLOWS source into an "outside the US" layer and an "inside the US" one.
  ///
  /// This is geography, not styling — without it the two networks draw the same
  /// rivers on top of each other in the US — so it survives the reset.
  static final Map<String, dynamic> _usMaskGeometry =
      jsonDecode(kUsBoundaryGeoJson) as Map<String, dynamic>;

  static List<Object> get _outsideUs => [
    '!',
    ['within', _usMaskGeometry],
  ];

  static List<Object> get _insideUs => ['within', _usMaskGeometry];

  /// Set the MapboxMap instance
  void setMapboxMap(MapboxMap map) {
    _mapboxMap = map;
    AppLogger.info('MapVectorTilesService', 'Vector tiles service ready');
  }

  /// Check if vector tiles are loaded
  bool get isLoaded => _isLoaded;

  /// Load both stream networks.
  Future<void> loadRiverReaches() async {
    if (_mapboxMap == null) {
      throw Exception('MapboxMap not set');
    }
    if (_isLoaded) {
      AppLogger.debug('MapVectorTilesService', 'Vector tiles already loaded');
      return;
    }

    try {
      await _removeExistingLayers();
      await _addSources();
      await _addLayers();
      await applyStreamVisibility(
        nwm: _nwmVisible,
        geoglowsWorld: _geoglowsWorldVisible,
        geoglowsUs: _geoglowsUsVisible,
      );
      _isLoaded = true;
      AppLogger.info(
        'MapVectorTilesService',
        'Stream networks loaded (unstyled baseline)',
      );
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Failed to load vector tiles', e);
      rethrow;
    }
  }

  Future<void> _addSources() async {
    final map = _mapboxMap!;
    await map.style.addSource(
      VectorSource(
        id: AppConfig.vectorSourceId,
        url: AppConfig.getVectorTileSourceUrl(),
      ),
    );
    await map.style.addSource(
      VectorSource(
        id: AppConfig.geoglowsSourceId,
        url: AppConfig.getGeoglowsTileSourceUrl(),
      ),
    );
    await map.style.addSource(
      VectorSource(
        id: AppConfig.floodSourceId,
        url: AppConfig.getFloodTileSourceUrl(),
      ),
    );
    AppLogger.info(
      'MapVectorTilesService',
      'Sources added: ${AppConfig.vectorSourceId}, ${AppConfig.geoglowsSourceId}, '
          '${AppConfig.floodSourceId}',
    );
  }

  Future<void> _addLayers() async {
    final map = _mapboxMap!;

    await map.style.addLayer(
      LineLayer(
        id: nwmLayerId,
        sourceId: AppConfig.vectorSourceId,
        sourceLayer: AppConfig.vectorSourceLayer,
        lineColor: _streamColor,
        lineOpacity: _lineOpacity,
        lineWidthExpression: _widthExpression(),
      ),
    );

    await map.style.addLayer(
      LineLayer(
        id: geoglowsLayerId,
        sourceId: AppConfig.geoglowsSourceId,
        sourceLayer: AppConfig.geoglowsSourceLayer,
        lineColor: _streamColor,
        lineOpacity: _lineOpacity,
        lineWidthExpression: _widthExpression(),
        filter: _outsideUs,
      ),
    );

    await map.style.addLayer(
      LineLayer(
        id: geoglowsUsLayerId,
        sourceId: AppConfig.geoglowsSourceId,
        sourceLayer: AppConfig.geoglowsSourceLayer,
        lineColor: _streamColor,
        lineOpacity: _lineOpacity,
        lineWidthExpression: _widthExpression(),
        filter: _insideUs,
      ),
    );

    // Pre-coloured flood reaches, drawn above everything. Colour comes from the
    // tile's own `cat` field, so there is no runtime expression carrying tens
    // of thousands of ids — the cost that made colouring take 8-12s before.
    await map.style.addLayer(
      LineLayer(
        id: floodLayerId,
        sourceId: AppConfig.floodSourceId,
        sourceLayer: AppConfig.floodSourceLayer,
        lineColorExpression: _floodColorExpression(),
        lineWidthExpression: _floodWidthExpression(),
        lineOpacity: 0.95,
      ),
    );
  }

  /// Master show/hide. When showing, each network returns to its own state —
  /// a network the user turned off stays off.
  Future<void> toggleRiverReachesVisibility({bool? visible}) async {
    if (_mapboxMap == null || !_isLoaded) return;
    final show = visible == true;
    try {
      await _setLayerVisibility(nwmLayerId, show && _nwmVisible);
      await _setLayerVisibility(geoglowsLayerId, show && _geoglowsWorldVisible);
      await _setLayerVisibility(geoglowsUsLayerId, show && _geoglowsUsVisible);
      AppLogger.info(
        'MapVectorTilesService',
        'River reaches ${show ? 'shown' : 'hidden'}',
      );
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Error toggling visibility', e);
    }
  }

  /// Set NWM (US) stream visibility.
  Future<void> setNwmVisible(bool visible) async {
    _nwmVisible = visible;
    await _setLayerVisibility(nwmLayerId, visible);
  }

  /// Set GEOGLOWS "outside the US" stream visibility.
  Future<void> setGeoglowsWorldVisible(bool visible) async {
    _geoglowsWorldVisible = visible;
    await _setLayerVisibility(geoglowsLayerId, visible);
  }

  /// Set GEOGLOWS "inside the US" stream visibility (off by default — it
  /// overlaps NWM).
  Future<void> setGeoglowsUsVisible(bool visible) async {
    _geoglowsUsVisible = visible;
    await _setLayerVisibility(geoglowsUsLayerId, visible);
  }

  /// Apply all three network toggles at once (e.g. restoring a saved choice).
  Future<void> applyStreamVisibility({
    required bool nwm,
    required bool geoglowsWorld,
    required bool geoglowsUs,
  }) async {
    await setNwmVisible(nwm);
    await setGeoglowsWorldVisible(geoglowsWorld);
    await setGeoglowsUsVisible(geoglowsUs);
  }

  Future<void> _setLayerVisibility(String layerId, bool visible) async {
    final map = _mapboxMap;
    if (map == null) return;
    try {
      await map.style.setStyleLayerProperty(
        layerId,
        'visibility',
        visible ? 'visible' : 'none',
      );
    } catch (e) {
      // Layer might not exist yet, that's fine.
    }
  }

  /// Remove vector tiles completely from the map.
  Future<void> removeRiverReaches() async {
    if (_mapboxMap == null || !_isLoaded) return;
    try {
      await _removeExistingLayers();
      _isLoaded = false;
      AppLogger.info('MapVectorTilesService', 'Vector tiles removed');
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Error removing vector tiles', e);
    }
  }

  Future<void> _removeExistingLayers() async {
    final map = _mapboxMap;
    if (map == null) return;
    for (final layerId in allLayerIds) {
      try {
        await map.style.removeStyleLayer(layerId);
      } catch (_) {
        // Layer might not exist, that's fine.
      }
    }
    for (final sourceId in [
      AppConfig.vectorSourceId,
      AppConfig.geoglowsSourceId,
      AppConfig.floodSourceId,
    ]) {
      try {
        await map.style.removeStyleSource(sourceId);
      } catch (_) {
        // Source might not exist, that's fine.
      }
    }
    AppLogger.debug('MapVectorTilesService', 'Cleaned up layers/sources');
  }

  /// Get current zoom level from map
  Future<double?> getCurrentZoom() async {
    if (_mapboxMap == null) return null;
    try {
      final cameraState = await _mapboxMap!.getCameraState();
      return cameraState.zoom;
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Error getting zoom level', e);
      return null;
    }
  }

  /// Dispose resources
  void dispose() {
    _mapboxMap = null;
    _isLoaded = false;
  }
}
