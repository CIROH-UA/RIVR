// lib/ui/2_presentation/features/map/widgets/stream_map_sheet.dart

import 'dart:convert';

import 'package:flutter/cupertino.dart';
// Mapbox exports its own `Size` which collides with Flutter's — hide it.
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Bottom sheet that shows a single stream highlighted on a 3D map.
///
/// The reach's real geometry comes straight from the same vector tiles the main
/// map uses: we add the tile source and filter a line layer down to this one
/// `station_id`, over a faint copy of the surrounding network for context. The
/// Mapbox Standard style provides 3D buildings; a terrain DEM adds hill relief.
class StreamMapSheet extends StatefulWidget {
  const StreamMapSheet({
    super.key,
    required this.reachId,
    required this.isGeoglows,
    required this.lat,
    required this.lon,
    required this.title,
    required this.highlightColor,
    this.subtitle,
  });

  final String reachId;
  final bool isGeoglows;
  final double lat;
  final double lon;
  final String title;
  final String? subtitle;
  final Color highlightColor;

  @override
  State<StreamMapSheet> createState() => _StreamMapSheetState();
}

class _StreamMapSheetState extends State<StreamMapSheet> {
  MapboxMap? _map;
  bool _framed = false;

  static const _brandNwm = 0xFF191970; // midnight blue
  static const _brandGeoglows = 0xFF1E88A8; // brand teal

  String get _sourceId => widget.isGeoglows ? 'sheet-geo-src' : 'sheet-nwm-src';
  String get _sourceLayer => widget.isGeoglows
      ? AppConfig.geoglowsSourceLayer
      : AppConfig.vectorSourceLayer;

  Future<void> _onStyleLoaded() async {
    final map = _map;
    if (map == null) return;

    final sourceId = _sourceId;
    final tileUrl = widget.isGeoglows
        ? AppConfig.getGeoglowsTileSourceUrl()
        : AppConfig.getVectorTileSourceUrl();
    final sourceLayer = _sourceLayer;
    final brand = widget.isGeoglows ? _brandGeoglows : _brandNwm;

    try {
      // Standard style config: daylight, 3D buildings, and place/road/POI
      // labels on, so the sheet reads with proper spatial context.
      try {
        const cfg = {
          'lightPreset': 'day',
          'show3dObjects': true,
          'showPlaceLabels': true,
          'showRoadLabels': true,
          'showPointOfInterestLabels': true,
          'showTransitLabels': true,
        };
        for (final e in cfg.entries) {
          await map.style
              .setStyleImportConfigProperty('basemap', e.key, e.value);
        }
      } catch (_) {}

      // Hill relief (Standard already renders 3D buildings when pitched).
      try {
        await map.style.addSource(RasterDemSource(
          id: 'mapbox-dem',
          url: 'mapbox://mapbox.mapbox-terrain-dem-v1',
          tileSize: 512,
          maxzoom: 14,
        ));
        await map.style.setStyleTerrainProperty('source', 'mapbox-dem');
        await map.style.setStyleTerrainProperty('exaggeration', 1.2);
      } catch (_) {
        // Terrain is a nice-to-have; ignore if it can't be added.
      }

      await map.style.addSource(VectorSource(id: sourceId, url: tileUrl));

      // The Mapbox Standard style occludes custom layers unless they're placed
      // in a slot; 'top' keeps the streams above the basemap.
      // Faint surrounding network for context. This rides the vector tiles, so
      // it naturally thins out as you zoom in — exactly what we want for context.
      await map.style.addLayer(LineLayer(
        id: 'sheet-context',
        sourceId: sourceId,
        sourceLayer: sourceLayer,
        slot: 'top',
        lineColor: brand,
        lineOpacity: 0.28,
        lineWidth: 1.4,
      ));

      // The highlighted reach itself is NOT drawn from the vector tiles: small
      // reaches are zoom-filtered out of the tiles, so they'd vanish the moment
      // we pull back for context. Instead [_frameStream] extracts this reach's
      // geometry once (while it's still in the loaded tiles), adds it as its own
      // GeoJSON source, and draws the casing + highlight from that — which stays
      // visible at any zoom. The initial camera below just needs to be close
      // enough that the reach is present in the loaded tiles to be captured.
      await map.setCamera(CameraOptions(
        center: Point(coordinates: Position(widget.lon, widget.lat)),
        zoom: 12.8,
        pitch: 50.0,
        bearing: 18.0,
      ));
    } catch (e) {
      AppLogger.error('StreamMapSheet', 'Failed to add stream layers', e);
    }
  }

  /// Once tiles load, pull this reach's geometry out of the loaded tiles, add it
  /// as its own GeoJSON source (unaffected by tile zoom-filtering so it stays
  /// visible when we pull back), draw the casing + highlight from it, then frame
  /// the camera wide enough to show the surrounding river network. Runs once; if
  /// the reach isn't in the loaded tiles the coordinate-centred view stays.
  Future<void> _frameStream() async {
    final map = _map;
    if (map == null || _framed) return;
    try {
      // A source-level filter here is unreliable (it silently returns the whole
      // viewport), so query broadly and match this reach's `station_id` in Dart.
      final feats = await map.querySourceFeatures(
        _sourceId,
        SourceQueryOptions(sourceLayerIds: [_sourceLayer], filter: ''),
      );

      final wantInt = int.tryParse(widget.reachId);

      // Collect every line segment of this reach (a reach can span several tile
      // features) into one MultiLineString.
      final lines = <List<Object?>>[];
      for (final f in feats) {
        final feature = f?.queriedFeature.feature;
        if (feature == null) continue;

        // Match by station_id — tiles store it as an int, but compare loosely.
        final props = feature['properties'];
        final sid = props is Map ? props['station_id'] : null;
        final matches = sid != null &&
            (sid == wantInt || sid.toString() == widget.reachId);
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
      if (lines.isEmpty) return;

      // Only commit once we've actually captured geometry — that way an early
      // idle over empty tiles doesn't lock us out of a later successful capture.
      _framed = true;

      final geometry = <String, Object?>{
        'type': 'MultiLineString',
        'coordinates': lines,
      };
      final featureCollection = <String, Object?>{
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': const <String, Object?>{},
            'geometry': geometry,
          }
        ],
      };

      final highlight = widget.highlightColor.toARGB32();

      await map.style.addSource(GeoJsonSource(
        id: 'sheet-reach-src',
        data: jsonEncode(featureCollection),
        lineMetrics: true,
      ));

      // Soft colored glow so the reach reads as "lit up" even against busy
      // basemap detail.
      await map.style.addLayer(LineLayer(
        id: 'sheet-glow',
        sourceId: 'sheet-reach-src',
        slot: 'top',
        lineColor: highlight,
        lineOpacity: 0.28,
        lineWidth: 16.0,
        lineBlur: 8.0,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
      ));

      // White casing so the colored core separates cleanly from the water/land.
      await map.style.addLayer(LineLayer(
        id: 'sheet-casing',
        sourceId: 'sheet-reach-src',
        slot: 'top',
        lineColor: 0xFFFFFFFF,
        lineOpacity: 0.95,
        lineWidth: 8.5,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
      ));

      // The highlighted reach itself, in the flood-category color.
      await map.style.addLayer(LineLayer(
        id: 'sheet-highlight',
        sourceId: 'sheet-reach-src',
        slot: 'top',
        lineColor: highlight,
        lineWidth: 4.0,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
      ));

      // Frame wide enough to see the reach against the surrounding network, but
      // keep it comfortably filling the view. Generous padding leaves context
      // (nearby town, the parent river) around it.
      final cam = await map.cameraForGeometry(
        geometry,
        MbxEdgeInsets(top: 120, left: 90, bottom: 120, right: 90),
        null,
        50.0,
      );
      final z = ((cam.zoom ?? 12.0) - 1.3).clamp(10.0, 12.5);
      await map.setCamera(CameraOptions(
          center: cam.center, zoom: z, pitch: 50.0, bearing: 18.0));
    } catch (e) {
      AppLogger.error('StreamMapSheet', 'Failed to frame stream', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = CupertinoColors.label.resolveFrom(context);
    final sub = CupertinoColors.secondaryLabel.resolveFrom(context);
    final mapHeight = MediaQuery.of(context).size.height * 0.52;

    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey3.resolveFrom(context),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                                color: label)),
                        if (widget.subtitle != null &&
                            widget.subtitle!.isNotEmpty)
                          Text(widget.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: sub)),
                      ],
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 0),
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Icon(CupertinoIcons.xmark_circle_fill,
                        size: 26,
                        color: CupertinoColors.systemGrey3.resolveFrom(context)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: mapHeight,
                  child: MapWidget(
                    key: const ValueKey('stream-map-sheet'),
                    cameraOptions: CameraOptions(
                      center: Point(
                          coordinates: Position(widget.lon, widget.lat)),
                      zoom: 13.6,
                      pitch: 56.0,
                    ),
                    styleUri: 'mapbox://styles/mapbox/standard',
                    textureView: true,
                    onMapCreated: (m) => _map = m,
                    onStyleLoadedListener: (_) => _onStyleLoaded(),
                    onMapIdleListener: (_) => _frameStream(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
