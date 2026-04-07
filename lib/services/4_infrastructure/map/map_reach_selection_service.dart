// lib/services/4_infrastructure/map/map_reach_selection_service.dart

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';
import 'package:rivr/models/1_domain/features/map/visible_stream.dart';

/// Service for handling river reach selection from vector tiles
/// Optimized for research teams to find streams by station ID
class MapReachSelectionService {
  MapboxMap? _mapboxMap;
  String? _currentHighlightLayerId;

  // Callbacks for selection events
  Function(SelectedReach)? onReachSelected;
  Function(Point)? onEmptyTap;

  /// Set the MapboxMap instance
  void setMapboxMap(MapboxMap map) {
    _mapboxMap = map;
    AppLogger.info('MapReachSelectionService', 'Research reach selection service ready');
  }

  /// Handle map tap for reach selection (keep existing functionality)
  Future<void> handleMapTap(MapContentGestureContext context) async {
    if (_mapboxMap == null) return;

    try {
      final tapPoint = context.point;
      final touchPosition = context.touchPosition;

      AppLogger.debug(
        'MapReachSelectionService',
        'Map tapped at: ${tapPoint.coordinates.lng}, ${tapPoint.coordinates.lat}',
      );

      final selectedReach = await _queryReachAtPoint(tapPoint, touchPosition);

      if (selectedReach != null) {
        AppLogger.info('MapReachSelectionService', 'Reach selected: ${selectedReach.reachId}');
        onReachSelected?.call(selectedReach);
      } else {
        AppLogger.debug('MapReachSelectionService', 'No reaches found at tap location');
        onEmptyTap?.call(tapPoint);
      }
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Error handling map tap', e);
      onEmptyTap?.call(context.point);
    }
  }

  /// Get all visible streams in current map view for research purposes.
  /// Pass [screenWidth] and [screenHeight] for proportional chunked queries.
  Future<List<VisibleStream>> getVisibleStreams({
    double screenWidth = 400,
    double screenHeight = 800,
  }) async {
    if (_mapboxMap == null) return [];

    AppLogger.debug('MapReachSelectionService', 'Querying visible streams...');

    final streams2LayerIds = [
      'streams2-order-1-2', // Small streams
      'streams2-order-3-4', // Medium streams
      'streams2-order-5-plus', // Large rivers
    ];

    final width = screenWidth;
    final height = screenHeight;

    // Strategy 1: Screen-aware chunked query (4 quadrants)
    var streams = await _tryChunkedQuery(streams2LayerIds, width, height);
    if (streams.isNotEmpty) {
      AppLogger.info('MapReachSelectionService', 'Chunked query successful: ${streams.length} streams found');
      return _sortStreams(streams);
    }

    // Strategy 2: Fallback center point query
    streams = await _tryCenterPointQuery(streams2LayerIds, width, height);
    if (streams.isNotEmpty) {
      AppLogger.info(
        'MapReachSelectionService',
        'Center point query successful: ${streams.length} streams found',
      );
      return _sortStreams(streams);
    }

    AppLogger.error('MapReachSelectionService', 'All query strategies failed - no streams found');
    return [];
  }

  /// Query screen in proportional chunks based on actual dimensions
  Future<List<VisibleStream>> _tryChunkedQuery(
    List<String> layerIds,
    double screenWidth,
    double screenHeight,
  ) async {
    try {
      AppLogger.debug('MapReachSelectionService', 'Trying chunked query (${screenWidth.toInt()}x${screenHeight.toInt()})...');

      final allStreams = <VisibleStream>[];
      final seenStationIds = <String>{};

      final halfW = screenWidth / 2;
      final halfH = screenHeight / 2;

      final chunks = [
        ScreenBox(
          min: ScreenCoordinate(x: 0, y: 0),
          max: ScreenCoordinate(x: halfW, y: halfH),
        ),
        ScreenBox(
          min: ScreenCoordinate(x: halfW, y: 0),
          max: ScreenCoordinate(x: screenWidth, y: halfH),
        ),
        ScreenBox(
          min: ScreenCoordinate(x: 0, y: halfH),
          max: ScreenCoordinate(x: halfW, y: screenHeight),
        ),
        ScreenBox(
          min: ScreenCoordinate(x: halfW, y: halfH),
          max: ScreenCoordinate(x: screenWidth, y: screenHeight),
        ),
      ];

      for (int i = 0; i < chunks.length; i++) {
        try {
          final queryResult = await _mapboxMap!.queryRenderedFeatures(
            RenderedQueryGeometry.fromScreenBox(chunks[i]),
            RenderedQueryOptions(layerIds: layerIds),
          );

          AppLogger.info('MapReachSelectionService', 'Chunk ${i + 1}: ${queryResult.length} features');

          for (final feature in queryResult) {
            if (feature != null) {
              final stream = _createVisibleStreamFromFeature(feature);
              if (stream != null &&
                  !seenStationIds.contains(stream.stationId)) {
                allStreams.add(stream);
                seenStationIds.add(stream.stationId);
              }
            }
          }
        } catch (e) {
          AppLogger.warning('MapReachSelectionService', 'Chunk ${i + 1} failed: $e');
          continue;
        }
      }

      return allStreams;
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Chunked query failed', e);
      return [];
    }
  }

  /// Fallback: Query around screen center
  Future<List<VisibleStream>> _tryCenterPointQuery(
    List<String> layerIds,
    double screenWidth,
    double screenHeight,
  ) async {
    try {
      AppLogger.debug('MapReachSelectionService', 'Trying center point query strategy...');

      final cx = screenWidth / 2;
      final cy = screenHeight / 2;
      final centerBox = ScreenBox(
        min: ScreenCoordinate(x: cx - 20, y: cy - 20),
        max: ScreenCoordinate(x: cx + 20, y: cy + 20),
      );

      final queryResult = await _mapboxMap!.queryRenderedFeatures(
        RenderedQueryGeometry.fromScreenBox(centerBox),
        RenderedQueryOptions(layerIds: layerIds),
      );

      AppLogger.info('MapReachSelectionService', 'Center point query: ${queryResult.length} features');

      final streams = <VisibleStream>[];
      final seenStationIds = <String>{};

      for (final feature in queryResult) {
        if (feature != null) {
          final stream = _createVisibleStreamFromFeature(feature);
          if (stream != null && !seenStationIds.contains(stream.stationId)) {
            streams.add(stream);
            seenStationIds.add(stream.stationId);
          }
        }
      }

      return streams;
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Center point query failed', e);
      return [];
    }
  }

  /// Create VisibleStream from feature
  VisibleStream? _createVisibleStreamFromFeature(
    QueriedRenderedFeature feature,
  ) {
    try {
      final featureData = feature.queriedFeature.feature;

      // Safe type conversion for properties
      final rawProperties = featureData['properties'];
      if (rawProperties == null) return null;

      final properties = Map<String, dynamic>.from(rawProperties as Map);

      if (!properties.containsKey('station_id') ||
          !properties.containsKey('streamOrder')) {
        return null;
      }

      // Safe type conversion for geometry
      final rawGeometry = featureData['geometry'];
      if (rawGeometry == null) return null;

      final geometry = Map<String, dynamic>.from(rawGeometry as Map);
      if (geometry['type'] != 'LineString') {
        return null;
      }

      final coordinates = geometry['coordinates'] as List;
      if (coordinates.isEmpty) return null;

      // Use middle point of LineString
      final middleIndex = coordinates.length ~/ 2;
      final middleCoord = coordinates[middleIndex] as List;

      AppLogger.info(
        'MapReachSelectionService',
        'Created stream: ${properties['station_id']} (Order ${properties['streamOrder']})',
      );

      return VisibleStream(
        stationId: properties['station_id'].toString(),
        streamOrder: properties['streamOrder'] as int,
        longitude: middleCoord[0].toDouble(),
        latitude: middleCoord[1].toDouble(),
      );
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Error creating VisibleStream', e);
      return null;
    }
  }

  /// Sort streams by stream order (larger first) then by station ID
  List<VisibleStream> _sortStreams(List<VisibleStream> streams) {
    streams.sort((a, b) {
      final orderCompare = b.streamOrder.compareTo(a.streamOrder);
      if (orderCompare != 0) return orderCompare;
      return a.stationId.compareTo(b.stationId);
    });
    return streams;
  }

  /// Fly to a selected stream and highlight it
  Future<void> flyToStream(VisibleStream stream) async {
    if (_mapboxMap == null) return;

    try {
      AppLogger.debug('MapReachSelectionService', 'Flying to stream ${stream.stationId}...');

      await clearHighlight();

      // Fly to stream location
      final cameraOptions = CameraOptions(
        center: Point(coordinates: Position(stream.longitude, stream.latitude)),
        zoom: 12.0,
      );

      await _mapboxMap!.flyTo(
        cameraOptions,
        MapAnimationOptions(duration: 1500, startDelay: 0),
      );

      // Highlight the stream
      await highlightStream(stream);

      AppLogger.info('MapReachSelectionService', 'Flew to and highlighted stream ${stream.stationId}');
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Error flying to stream', e);
    }
  }

  /// Highlight a stream on the map
  Future<void> highlightStream(VisibleStream stream) async {
    if (_mapboxMap == null) return;

    try {
      await clearHighlight();

      final highlightSourceId = 'stream-highlight-source';
      final highlightLayerId = 'stream-highlight-layer';

      final streamPointGeoJson =
          '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": {
        "type": "Point",
        "coordinates": [${stream.longitude}, ${stream.latitude}]
      },
      "properties": {
        "station_id": "${stream.stationId}"
      }
    }
  ]
}
''';

      await _mapboxMap!.style.addSource(
        GeoJsonSource(id: highlightSourceId, data: streamPointGeoJson),
      );

      await _mapboxMap!.style.addLayer(
        CircleLayer(
          id: highlightLayerId,
          sourceId: highlightSourceId,
          circleColor: 0xFFFF0000, // Bright red
          circleRadius: 12.0,
          circleOpacity: 0.7,
          circleStrokeColor: 0xFFFFFFFF, // White border
          circleStrokeWidth: 2.0,
        ),
      );

      _currentHighlightLayerId = highlightLayerId;
      AppLogger.info('MapReachSelectionService', 'Highlighted stream ${stream.stationId}');

      // Auto-clear highlight after 5 seconds
      Future.delayed(const Duration(seconds: 5), () {
        clearHighlight();
      });
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Error highlighting stream', e);
    }
  }

  /// Clear stream highlight
  Future<void> clearHighlight() async {
    if (_mapboxMap == null || _currentHighlightLayerId == null) return;

    try {
      await _mapboxMap!.style.removeStyleLayer(_currentHighlightLayerId!);
      await _mapboxMap!.style.removeStyleSource('stream-highlight-source');
      _currentHighlightLayerId = null;
      AppLogger.info('MapReachSelectionService', 'Cleared stream highlight');
    } catch (e) {
      _currentHighlightLayerId = null;
    }
  }

  /// Query vector tile features at specific point (working functionality)
  Future<SelectedReach?> _queryReachAtPoint(
    Point tapPoint,
    ScreenCoordinate touchPosition,
  ) async {
    if (_mapboxMap == null) return null;

    try {
      final queryBox = RenderedQueryGeometry.fromScreenBox(
        ScreenBox(
          min: ScreenCoordinate(
            x: touchPosition.x - 12,
            y: touchPosition.y - 12,
          ),
          max: ScreenCoordinate(
            x: touchPosition.x + 12,
            y: touchPosition.y + 12,
          ),
        ),
      );

      final streams2LayerIds = [
        'streams2-order-1-2',
        'streams2-order-3-4',
        'streams2-order-5-plus',
      ];

      final List<QueriedRenderedFeature?> queryResult = await _mapboxMap!
          .queryRenderedFeatures(
            queryBox,
            RenderedQueryOptions(layerIds: streams2LayerIds),
          );

      AppLogger.debug('MapReachSelectionService', 'Found ${queryResult.length} streams2 features in tap query');

      for (final queriedRenderedFeature in queryResult) {
        if (queriedRenderedFeature != null) {
          try {
            final selectedReach = _createSelectedReachFromFeature(
              queriedRenderedFeature,
              tapPoint,
            );
            if (selectedReach != null) {
              return selectedReach;
            }
          } catch (e) {
            AppLogger.warning('MapReachSelectionService', 'Error processing streams2 feature: $e');
          }
        }
      }

      return null;
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Error querying features', e);
      return null;
    }
  }

  /// Create SelectedReach from vector tile feature
  SelectedReach? _createSelectedReachFromFeature(
    QueriedRenderedFeature queriedRenderedFeature,
    Point tapPoint,
  ) {
    try {
      final feature = queriedRenderedFeature.queriedFeature.feature;

      // Safe type conversion for properties
      final rawProperties = feature['properties'];
      if (rawProperties == null) return null;

      final properties = Map<String, dynamic>.from(rawProperties as Map);

      AppLogger.debug('MapReachSelectionService', 'Feature properties: ${properties.keys.toList()}');
      AppLogger.debug('MapReachSelectionService', 'station_id: ${properties['station_id']}');
      AppLogger.debug('MapReachSelectionService', 'streamOrder: ${properties['streamOrder']}');

      if (!properties.containsKey('station_id') ||
          !properties.containsKey('streamOrder')) {
        AppLogger.error('MapReachSelectionService', 'Missing required properties (station_id or streamOrder)');
        return null;
      }

      return SelectedReach.fromVectorTile(
        properties: properties,
        latitude: tapPoint.coordinates.lat.toDouble(),
        longitude: tapPoint.coordinates.lng.toDouble(),
      );
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Error creating SelectedReach', e);
      return null;
    }
  }

  /// Dispose resources
  void dispose() {
    clearHighlight();
    _mapboxMap = null;
    onReachSelected = null;
    onEmptyTap = null;
    AppLogger.debug('MapReachSelectionService', 'Research reach selection service disposed');
  }
}
