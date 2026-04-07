// lib/services/4_infrastructure/map/map_vector_tiles_service.dart

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Service for managing vector tiles display on the map
/// Handles loading/removing river reaches from vector tiles
class MapVectorTilesService {
  MapboxMap? _mapboxMap;
  bool _isLoaded = false;

  static const int _streamColor = 0xFF191970; // Midnight blue

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

      _isLoaded = true;
      AppLogger.info('MapVectorTilesService', 'River reaches vector tiles loaded successfully');
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Failed to load vector tiles', e);
      rethrow;
    }
  }

  /// Toggle river reaches visibility on/off
  Future<void> toggleRiverReachesVisibility({bool? visible}) async {
    if (_mapboxMap == null || !_isLoaded) return;

    try {
      final layerIds = [
        'streams2-debug-correct',
        'streams2-order-1-2',
        'streams2-order-3-4',
        'streams2-order-5-plus',
      ];

      for (final layerId in layerIds) {
        try {
          await _mapboxMap!.style.setStyleLayerProperty(
            layerId,
            'visibility',
            visible == true ? 'visible' : 'none',
          );
        } catch (e) {
          // Layer might not exist, that's fine
        }
      }

      AppLogger.info('MapVectorTilesService', 'River reaches ${visible == true ? 'shown' : 'hidden'}');
    } catch (e) {
      AppLogger.error('MapVectorTilesService', 'Error toggling river reaches visibility', e);
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
      ];

      // Try to remove layers first
      for (final layerId in layersToRemove) {
        try {
          await _mapboxMap!.style.removeStyleLayer(layerId);
        } catch (e) {
          // Layer might not exist, that's fine
        }
      }

      // Then remove source
      try {
        await _mapboxMap!.style.removeStyleSource(AppConfig.vectorSourceId);
      } catch (e) {
        // Source might not exist, that's fine
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
      // Simple visibility toggle based on zoom thresholds
      final shouldShow =
          zoom >= AppConfig.minZoomForVectorTiles &&
          zoom <= AppConfig.maxZoomForVectorTiles;

      final layerIds = [
        'streams2-debug-correct',
        'streams2-order-1-2',
        'streams2-order-3-4',
        'streams2-order-5-plus',
      ];

      for (final layerId in layerIds) {
        try {
          await _mapboxMap!.style.setStyleLayerProperty(
            layerId,
            'visibility',
            shouldShow ? 'visible' : 'none',
          );
        } catch (e) {
          // Layer might not exist, that's fine
        }
      }
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
