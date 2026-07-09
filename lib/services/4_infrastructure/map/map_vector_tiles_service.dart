// lib/services/4_infrastructure/map/map_vector_tiles_service.dart

import 'dart:convert';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/map/us_boundary_mask.dart';

/// Service for managing vector tiles display on the map
/// Handles loading/removing river reaches from vector tiles
class MapVectorTilesService {
  MapboxMap? _mapboxMap;
  bool _isLoaded = false;

  static const int _streamColor = 0xFF191970; // Midnight blue (NWM)
  static const int _geoglowsColor = 0xFF1E88A8; // Brand teal (GEOGLOWS)

  /// NWM stream layer ids (US only, by the tileset's own extent).
  static const List<String> _nwmLayerIds = [
    'streams2-order-1-2',
    'streams2-order-3-4',
    'streams2-order-5-plus',
  ];

  /// GEOGLOWS layers that render OUTSIDE the US (world tileset, US masked out).
  /// Must keep the `geoglows` prefix so tap-selection resolves the source
  /// (see ForecastSource.fromLayerIds).
  static const List<String> _geoglowsWorldLayerIds = [
    'geoglows-order-1-2',
    'geoglows-order-3-4',
    'geoglows-order-5-plus',
  ];

  /// GEOGLOWS layers that render INSIDE the US only (same source, inverse mask).
  /// Off by default — NWM owns the US unless the user opts in.
  static const List<String> _geoglowsUsLayerIds = [
    'geoglows-us-order-1-2',
    'geoglows-us-order-3-4',
    'geoglows-us-order-5-plus',
  ];

  static const List<String> _allGeoglowsLayerIds = [
    ..._geoglowsWorldLayerIds,
    ..._geoglowsUsLayerIds,
  ];

  // Per-network desired visibility (the Auto default: NWM + GEOGLOWS outside US,
  // GEOGLOWS-in-US off). Zoom gating multiplies these — a layer shows only when
  // its network is enabled AND the zoom is in range.
  bool _nwmVisible = true;
  bool _geoglowsWorldVisible = true;
  bool _geoglowsUsVisible = false;

  /// GEOGLOWS defers to NWM inside the US: this simplified US boundary
  /// (CONUS + Alaska + Hawaii, see [kUsBoundaryGeoJson]) is masked out of the
  /// GEOGLOWS world layers by default, so NWM owns the US and GEOGLOWS renders
  /// only outside it (the Auto default). Following the actual border (rather
  /// than a bounding box) avoids the empty band across northern Mexico and the
  /// overlap into southern British Columbia the old bbox mask produced.
  static final Map<String, dynamic> _usMaskGeometry =
      jsonDecode(kUsBoundaryGeoJson) as Map<String, dynamic>;

  /// Combine a stream-order [orderFilter] with the "outside the US" mask so a
  /// GEOGLOWS layer skips anything fully inside [_usMaskGeometry].
  static List<Object> _outsideUs(List<Object> orderFilter) => [
    'all',
    orderFilter,
    [
      '!',
      ['within', _usMaskGeometry],
    ],
  ];

  /// Combine a stream-order [orderFilter] with the "inside the US" mask so a
  /// GEOGLOWS layer keeps only what falls within [_usMaskGeometry].
  static List<Object> _insideUs(List<Object> orderFilter) => [
    'all',
    orderFilter,
    ['within', _usMaskGeometry],
  ];

  /// Set the MapboxMap instance
  void setMapboxMap(MapboxMap map) {
    _mapboxMap = map;
    AppLogger.info('MapVectorTilesService', 'Vector tiles service ready');
  }

  /// Load river reaches vector tiles
  Future<void> loadRiverReaches() async {
    if (_mapboxMap == null) {
      throw Exception('MapboxMap not set');
    }

    if (_isLoaded) {
      AppLogger.debug('MapVectorTilesService', 'Vector tiles already loaded');
      return;
    }

    try {
      AppLogger.debug('MapVectorTilesService', 'Loading river reaches vector tiles...');

      // Remove existing source/layers if they exist
      await _removeExistingLayers();

      // Add vector source
      await _addVectorSource();

      // Add the CORRECT styled layers (multiple layers like working code)
      await _addStyledLayers();

      // Add GEOGLOWS streams (global, non-US) as their own source + layers.
      await _addGeoglowsSourceAndLayers();

      // Apply the current per-network visibility (Auto default hides GEOGLOWS
      // inside the US until the user turns that layer on).
      await applyStreamVisibility(
        nwm: _nwmVisible,
        geoglowsWorld: _geoglowsWorldVisible,
        geoglowsUs: _geoglowsUsVisible,
      );

      _isLoaded = true;
      AppLogger.info('MapVectorTilesService', 'River reaches vector tiles loaded successfully');
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Failed to load vector tiles', e);
      rethrow;
    }
  }

  /// Master show/hide for all stream reaches. When showing, each network is
  /// restored to its per-network desired state (a disabled network stays off).
  Future<void> toggleRiverReachesVisibility({bool? visible}) async {
    if (_mapboxMap == null || !_isLoaded) return;

    final show = visible == true;
    try {
      await _setLayerGroupVisibility(_nwmLayerIds, show && _nwmVisible);
      await _setLayerGroupVisibility(
        _geoglowsWorldLayerIds,
        show && _geoglowsWorldVisible,
      );
      await _setLayerGroupVisibility(
        _geoglowsUsLayerIds,
        show && _geoglowsUsVisible,
      );
      AppLogger.info('MapVectorTilesService', 'River reaches ${show ? 'shown' : 'hidden'}');
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Error toggling river reaches visibility', e);
    }
  }

  /// Set NWM (US) stream visibility. Persisted choice lives in the caller.
  Future<void> setNwmVisible(bool visible) async {
    _nwmVisible = visible;
    await _setLayerGroupVisibility(_nwmLayerIds, visible);
  }

  /// Set GEOGLOWS "outside the US" stream visibility.
  Future<void> setGeoglowsWorldVisible(bool visible) async {
    _geoglowsWorldVisible = visible;
    await _setLayerGroupVisibility(_geoglowsWorldLayerIds, visible);
  }

  /// Set GEOGLOWS "US area" stream visibility (off by default — overlaps NWM).
  Future<void> setGeoglowsUsVisible(bool visible) async {
    _geoglowsUsVisible = visible;
    await _setLayerGroupVisibility(_geoglowsUsLayerIds, visible);
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

  Future<void> _setLayerGroupVisibility(
    List<String> layerIds,
    bool visible,
  ) async {
    if (_mapboxMap == null) return;
    for (final layerId in layerIds) {
      try {
        await _mapboxMap!.style.setStyleLayerProperty(
          layerId,
          'visibility',
          visible ? 'visible' : 'none',
        );
      } catch (e) {
        // Layer might not exist yet, that's fine
      }
    }
  }

  /// Remove vector tiles completely from map (for cleanup/switching layers)
  Future<void> removeRiverReaches() async {
    if (_mapboxMap == null || !_isLoaded) return;

    try {
      await _removeExistingLayers();
      _isLoaded = false;
      AppLogger.info('MapVectorTilesService', 'Vector tiles removed completely');
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Error removing vector tiles', e);
    }
  }

  /// Check if vector tiles are loaded
  bool get isLoaded => _isLoaded;

  /// Add the vector source for river reaches
  Future<void> _addVectorSource() async {
    await _mapboxMap!.style.addSource(
      VectorSource(
        id: AppConfig.vectorSourceId,
        url: AppConfig.getVectorTileSourceUrl(),
      ),
    );
    AppLogger.info('MapVectorTilesService', 'Vector source added: ${AppConfig.vectorSourceId}');
  }

  /// Add styled layers for river reaches (MULTIPLE LAYERS like working code)
  Future<void> _addStyledLayers() async {
    try {
      final color = _streamColor;

      // Add stream order layers with proper styling and filters
      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'streams2-order-1-2',
          sourceId: AppConfig.vectorSourceId,
          sourceLayer: AppConfig.vectorSourceLayer,
          lineColor: color,
          lineWidth: 1.0,
          lineOpacity: 0.8,
          filter: [
            "<=",
            ["get", "streamOrder"],
            2,
          ],
        ),
      );
      AppLogger.info('MapVectorTilesService', 'Added layer: streams2-order-1-2');

      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'streams2-order-3-4',
          sourceId: AppConfig.vectorSourceId,
          sourceLayer: AppConfig.vectorSourceLayer,
          lineColor: color,
          lineWidth: 2.0,
          lineOpacity: 0.8,
          filter: [
            "all",
            [
              ">=",
              ["get", "streamOrder"],
              3,
            ],
            [
              "<=",
              ["get", "streamOrder"],
              4,
            ],
          ],
        ),
      );
      AppLogger.info('MapVectorTilesService', 'Added layer: streams2-order-3-4');

      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'streams2-order-5-plus',
          sourceId: AppConfig.vectorSourceId,
          sourceLayer: AppConfig.vectorSourceLayer,
          lineColor: color,
          lineWidth: 3.5,
          lineOpacity: 0.9,
          filter: [
            ">=",
            ["get", "streamOrder"],
            5,
          ],
        ),
      );
      AppLogger.info('MapVectorTilesService', 'Added layer: streams2-order-5-plus');
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Failed to add styled layers', e);
      rethrow;
    }
  }

  /// Add the GEOGLOWS vector source + stream-order layers (global rivers).
  /// Mirrors the NWM layer styling but with the brand-teal color and
  /// `geoglows-*` layer ids that drive source-routing on tap.
  Future<void> _addGeoglowsSourceAndLayers() async {
    try {
      await _mapboxMap!.style.addSource(
        VectorSource(
          id: AppConfig.geoglowsSourceId,
          url: AppConfig.getGeoglowsTileSourceUrl(),
        ),
      );

      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'geoglows-order-1-2',
          sourceId: AppConfig.geoglowsSourceId,
          sourceLayer: AppConfig.geoglowsSourceLayer,
          lineColor: _geoglowsColor,
          lineWidth: 1.0,
          lineOpacity: 0.8,
          filter: _outsideUs(["<=", ["get", "streamOrder"], 2]),
        ),
      );
      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'geoglows-order-3-4',
          sourceId: AppConfig.geoglowsSourceId,
          sourceLayer: AppConfig.geoglowsSourceLayer,
          lineColor: _geoglowsColor,
          lineWidth: 2.0,
          lineOpacity: 0.8,
          filter: _outsideUs([
            "all",
            [">=", ["get", "streamOrder"], 3],
            ["<=", ["get", "streamOrder"], 4],
          ]),
        ),
      );
      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'geoglows-order-5-plus',
          sourceId: AppConfig.geoglowsSourceId,
          sourceLayer: AppConfig.geoglowsSourceLayer,
          lineColor: _geoglowsColor,
          lineWidth: 3.5,
          lineOpacity: 0.9,
          filter: _outsideUs([">=", ["get", "streamOrder"], 5]),
        ),
      );

      // GEOGLOWS INSIDE the US (same source, inverse mask). Added hidden by
      // default; `applyStreamVisibility` sets the actual state after load.
      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'geoglows-us-order-1-2',
          sourceId: AppConfig.geoglowsSourceId,
          sourceLayer: AppConfig.geoglowsSourceLayer,
          lineColor: _geoglowsColor,
          lineWidth: 1.0,
          lineOpacity: 0.8,
          visibility: Visibility.NONE,
          filter: _insideUs(["<=", ["get", "streamOrder"], 2]),
        ),
      );
      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'geoglows-us-order-3-4',
          sourceId: AppConfig.geoglowsSourceId,
          sourceLayer: AppConfig.geoglowsSourceLayer,
          lineColor: _geoglowsColor,
          lineWidth: 2.0,
          lineOpacity: 0.8,
          visibility: Visibility.NONE,
          filter: _insideUs([
            "all",
            [">=", ["get", "streamOrder"], 3],
            ["<=", ["get", "streamOrder"], 4],
          ]),
        ),
      );
      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'geoglows-us-order-5-plus',
          sourceId: AppConfig.geoglowsSourceId,
          sourceLayer: AppConfig.geoglowsSourceLayer,
          lineColor: _geoglowsColor,
          lineWidth: 3.5,
          lineOpacity: 0.9,
          visibility: Visibility.NONE,
          filter: _insideUs([">=", ["get", "streamOrder"], 5]),
        ),
      );
      AppLogger.info('MapVectorTilesService', 'Added GEOGLOWS layers');
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Failed to add GEOGLOWS layers', e);
      // Non-fatal: NWM streams still render if GEOGLOWS fails.
    }
  }

  /// Remove existing vector source and layers to avoid conflicts
  Future<void> _removeExistingLayers() async {
    try {
      // Remove all possible layer IDs
      final layersToRemove = [
        'streams2-debug-correct',
        'streams2-order-1-2',
        'streams2-order-3-4',
        'streams2-order-5-plus',
        AppConfig.vectorLayerId, // Also remove the old generic layer
        ..._allGeoglowsLayerIds,
      ];

      // Try to remove layers first
      for (final layerId in layersToRemove) {
        try {
          await _mapboxMap!.style.removeStyleLayer(layerId);
        } catch (e) {
          // Layer might not exist, that's fine
        }
      }

      // Then remove sources
      for (final sourceId in [
        AppConfig.vectorSourceId,
        AppConfig.geoglowsSourceId,
      ]) {
        try {
          await _mapboxMap!.style.removeStyleSource(sourceId);
        } catch (e) {
          // Source might not exist, that's fine
        }
      }

      AppLogger.debug('MapVectorTilesService', 'Cleaned up existing layers/sources');
    } catch (e) {
      // Ignore errors when removing non-existent layers/sources
      AppLogger.debug('MapVectorTilesService', 'Cleaned up existing layers/sources');
    }
  }

  /// Update layer visibility based on zoom level
  /// Called when zoom changes to optimize performance
  Future<void> updateVisibilityForZoom(double zoom) async {
    if (!_isLoaded || _mapboxMap == null) return;

    try {
      // Simple visibility toggle based on zoom thresholds. Effective visibility
      // is (in zoom range) AND (network enabled), so zoom gating never turns a
      // user-disabled network back on.
      final shouldShow =
          zoom >= AppConfig.minZoomForVectorTiles &&
          zoom <= AppConfig.maxZoomForVectorTiles;

      await _setLayerGroupVisibility(_nwmLayerIds, shouldShow && _nwmVisible);
      await _setLayerGroupVisibility(
        _geoglowsWorldLayerIds,
        shouldShow && _geoglowsWorldVisible,
      );
      await _setLayerGroupVisibility(
        _geoglowsUsLayerIds,
        shouldShow && _geoglowsUsVisible,
      );
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Error updating layer visibility', e);
    }
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
