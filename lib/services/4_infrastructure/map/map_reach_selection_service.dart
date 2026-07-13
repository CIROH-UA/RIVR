// lib/services/4_infrastructure/map/map_reach_selection_service.dart

import 'dart:convert';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';
import 'package:rivr/models/1_domain/features/map/visible_stream.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';

/// Service for handling river reach selection from vector tiles
/// Optimized for research teams to find streams by station ID
class MapReachSelectionService {
  MapboxMap? _mapboxMap;
  String? _currentHighlightLayerId;

  // Line-highlight of the tapped reach (glow + white casing + colored core over
  // a GeoJSON source). Kept separate from the legacy point highlight above.
  static const _hlSource = 'tap-highlight-source';
  static const _hlGlow = 'tap-highlight-glow';
  static const _hlCasing = 'tap-highlight-casing';
  static const _hlCore = 'tap-highlight-core';
  // Gold reads as "selected" against both blue water and green land; it's the
  // default until the details sheet loads the flood category and recolors it.
  static const _selectionColor = 0xFFFFC400;
  // Both tilesets expose their streams under the same source-layer.
  static const _channelsSourceLayer = 'channels';
  bool _lineHighlightAdded = false;
  // A category color that arrived before the highlight was on the map; applied
  // once the layers exist.
  int? _pendingRecolor;

  // The most recently tapped reach — its tile source id + station id let us pull
  // the *whole* reach geometry, and the clipped tile segment is kept as a
  // fallback if the full-source query comes up empty.
  String? _lastTappedSourceId;
  String? _lastTappedReachId;
  Map<String, dynamic>? _lastTappedGeometry;

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

      // Reset stale selection so an empty tap can't reuse the previous reach's.
      _lastTappedGeometry = null;
      _lastTappedSourceId = null;
      _lastTappedReachId = null;

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
      'streams2-order-1-2', // Small streams (NWM)
      'streams2-order-3-4', // Medium streams (NWM)
      'streams2-order-5-plus', // Large rivers (NWM)
      'geoglows-order-1-2', // GEOGLOWS outside the US
      'geoglows-order-3-4',
      'geoglows-order-5-plus',
      'geoglows-us-order-1-2', // GEOGLOWS inside the US (Compare/Global modes)
      'geoglows-us-order-3-4',
      'geoglows-us-order-5-plus',
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

  /// Highlight the most recently tapped reach as a bright line following the
  /// stream geometry (soft glow + white casing + colored core), so it's obvious
  /// which stream the details sheet refers to. Traces the *whole* reach (every
  /// tile segment for its station id), falling back to the tapped tile segment.
  /// Starts gold; [recolorHighlight] swaps in the flood-category color once the
  /// sheet loads it. Reuses the source/layers on repeat taps, swapping geometry.
  Future<void> highlightSelectedReach() async {
    final map = _mapboxMap;
    if (map == null) return;

    final geom = await _fullReachGeometry() ?? _lastTappedGeometry;
    if (geom == null) return;

    final featureCollection = jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {'type': 'Feature', 'properties': const {}, 'geometry': geom},
      ],
    });

    try {
      if (_lineHighlightAdded) {
        await map.style
            .setStyleSourceProperty(_hlSource, 'data', featureCollection);
        // New selection starts gold again until its category loads.
        _pendingRecolor = null;
        await _applyHighlightColor(_selectionColor);
        return;
      }

      await map.style.addSource(GeoJsonSource(
        id: _hlSource,
        data: featureCollection,
        lineMetrics: true,
      ));

      // Soft colored glow so the reach reads as "lit up".
      await map.style.addLayer(LineLayer(
        id: _hlGlow,
        sourceId: _hlSource,
        lineColor: _selectionColor,
        lineOpacity: 0.30,
        lineWidth: 16.0,
        lineBlur: 8.0,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
      ));

      // White casing separates the core from the water/land beneath.
      await map.style.addLayer(LineLayer(
        id: _hlCasing,
        sourceId: _hlSource,
        lineColor: 0xFFFFFFFF,
        lineOpacity: 0.95,
        lineWidth: 9.0,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
      ));

      // The selection-colored core.
      await map.style.addLayer(LineLayer(
        id: _hlCore,
        sourceId: _hlSource,
        lineColor: _selectionColor,
        lineWidth: 4.5,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
      ));

      _lineHighlightAdded = true;

      // A category color may have arrived while we were adding the layers.
      if (_pendingRecolor != null) {
        final c = _pendingRecolor!;
        _pendingRecolor = null;
        await _applyHighlightColor(c);
      }
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Error highlighting reach line', e);
    }
  }

  /// Recolor the highlight's glow + core to [argb] (the flood-category color)
  /// once the details sheet has classified the flow. Queued if the highlight
  /// isn't on the map yet.
  Future<void> recolorHighlight(int argb) async {
    if (!_lineHighlightAdded) {
      _pendingRecolor = argb;
      return;
    }
    await _applyHighlightColor(argb);
  }

  /// Pull the full geometry for the last-tapped reach by querying its tile
  /// source for every segment sharing the station id (the tapped tile feature is
  /// clipped to a tile, so a long reach would otherwise stop at a tile edge).
  Future<Map<String, dynamic>?> _fullReachGeometry() async {
    final map = _mapboxMap;
    final src = _lastTappedSourceId;
    final id = _lastTappedReachId;
    if (map == null || src == null || id == null) return null;

    try {
      // The source-level filter is unreliable (returns the whole viewport), so
      // query broadly and match the station id in Dart.
      final feats = await map.querySourceFeatures(
        src,
        SourceQueryOptions(sourceLayerIds: [_channelsSourceLayer], filter: ''),
      );
      final wantInt = int.tryParse(id);
      final lines = <List<Object?>>[];
      for (final f in feats) {
        final feature = f?.queriedFeature.feature;
        if (feature == null) continue;
        final props = feature['properties'];
        final sid = props is Map ? props['station_id'] : null;
        final matches =
            sid != null && (sid == wantInt || sid.toString() == id);
        if (!matches) continue;
        final g = feature['geometry'];
        if (g is! Map) continue;
        final type = g['type'];
        final coords = g['coordinates'];
        if (type == 'LineString' && coords is List) {
          lines.add(List<Object?>.from(coords));
        } else if (type == 'MultiLineString' && coords is List) {
          for (final seg in coords) {
            if (seg is List) lines.add(List<Object?>.from(seg));
          }
        }
      }
      if (lines.isEmpty) return null;
      return {'type': 'MultiLineString', 'coordinates': lines};
    } catch (e) {
      AppLogger.warning('MapReachSelectionService', 'Full-reach query failed: $e');
      return null;
    }
  }

  /// Apply a color to the glow + core highlight layers. Mapbox's runtime
  /// style setter wants a color string, so encode as `rgba(...)`.
  Future<void> _applyHighlightColor(int argb) async {
    final map = _mapboxMap;
    if (map == null || !_lineHighlightAdded) return;
    final a = ((argb >> 24) & 0xFF) / 255.0;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    final rgba = 'rgba($r, $g, $b, $a)';
    try {
      await map.style.setStyleLayerProperty(_hlCore, 'line-color', rgba);
      await map.style.setStyleLayerProperty(_hlGlow, 'line-color', rgba);
    } catch (e) {
      AppLogger.warning('MapReachSelectionService', 'Recolor failed: $e');
    }
  }

  /// Remove the tapped-reach line highlight (call when the details sheet closes).
  Future<void> clearLineHighlight() async {
    final map = _mapboxMap;
    if (map == null || !_lineHighlightAdded) return;
    try {
      for (final id in [_hlCore, _hlCasing, _hlGlow]) {
        try {
          await map.style.removeStyleLayer(id);
        } catch (_) {}
      }
      try {
        await map.style.removeStyleSource(_hlSource);
      } catch (_) {}
    } finally {
      _lineHighlightAdded = false;
      _pendingRecolor = null;
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
        'geoglows-order-1-2',
        'geoglows-order-3-4',
        'geoglows-order-5-plus',
        'geoglows-us-order-1-2',
        'geoglows-us-order-3-4',
        'geoglows-us-order-5-plus',
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

      // Capture what we need to highlight the whole reach: its tile source id +
      // station id (to query every segment), plus the tapped tile's clipped
      // LineString/MultiLineString as a fallback.
      _lastTappedSourceId = queriedRenderedFeature.queriedFeature.source;
      _lastTappedReachId = properties['station_id'].toString();
      final rawGeometry = feature['geometry'];
      if (rawGeometry is Map) {
        final geom = Map<String, dynamic>.from(rawGeometry);
        final type = geom['type'];
        if (type == 'LineString' || type == 'MultiLineString') {
          _lastTappedGeometry = geom;
        }
      }

      // Determine the data source from the tapped feature's tile source +
      // layers (GEOGLOWS source/layers are prefixed `geoglows`; else NWM).
      // `source` is always populated; `layers` can be empty, so check both.
      final source = ForecastSource.fromLayerIds([
        queriedRenderedFeature.queriedFeature.source,
        ...queriedRenderedFeature.layers,
      ]);

      return SelectedReach.fromVectorTile(
        properties: properties,
        latitude: tapPoint.coordinates.lat.toDouble(),
        longitude: tapPoint.coordinates.lng.toDouble(),
        source: source,
      );
    } catch (e) {
      AppLogger.error('MapReachSelectionService', 'Error creating SelectedReach', e);
      return null;
    }
  }

  /// Dispose resources
  void dispose() {
    clearHighlight();
    clearLineHighlight();
    _mapboxMap = null;
    onReachSelected = null;
    onEmptyTap = null;
    AppLogger.debug('MapReachSelectionService', 'Research reach selection service disposed');
  }
}
