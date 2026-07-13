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

  /// Filter matching this one reach by its tile id. The tiles store `station_id`
  /// as an int, so compare numerically (Mapbox filters don't apply a `to-string`
  /// coercion reliably here); fall back to the raw string for non-numeric ids.
  List<Object> get _reachFilter {
    final asInt = int.tryParse(widget.reachId);
    return <Object>[
      '==',
      <Object>['get', 'station_id'],
      asInt ?? widget.reachId,
    ];
  }

  Future<void> _onStyleLoaded() async {
    final map = _map;
    if (map == null) return;

    final sourceId = _sourceId;
    final tileUrl = widget.isGeoglows
        ? AppConfig.getGeoglowsTileSourceUrl()
        : AppConfig.getVectorTileSourceUrl();
    final sourceLayer = _sourceLayer;
    final brand = widget.isGeoglows ? _brandGeoglows : _brandNwm;
    final onlyThisReach = _reachFilter;

    try {
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
      // Faint surrounding network for context.
      await map.style.addLayer(LineLayer(
        id: 'sheet-context',
        sourceId: sourceId,
        sourceLayer: sourceLayer,
        slot: 'top',
        lineColor: brand,
        lineOpacity: 0.45,
        lineWidth: 1.4,
      ));

      // White casing under the highlight so it reads over any basemap.
      await map.style.addLayer(LineLayer(
        id: 'sheet-casing',
        sourceId: sourceId,
        sourceLayer: sourceLayer,
        slot: 'top',
        lineColor: 0xFFFFFFFF,
        lineOpacity: 0.95,
        lineWidth: 8.0,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
        filter: onlyThisReach,
      ));

      // The highlighted stream itself.
      await map.style.addLayer(LineLayer(
        id: 'sheet-highlight',
        sourceId: sourceId,
        sourceLayer: sourceLayer,
        slot: 'top',
        lineColor: widget.highlightColor.toARGB32(),
        lineWidth: 4.0,
        lineCap: LineCap.ROUND,
        lineJoin: LineJoin.ROUND,
        lineEmissiveStrength: 1.0,
        filter: onlyThisReach,
      ));

      // Initial framing on the reach's coordinate (which sits on the stream),
      // pitched for the 3D view. Refined to the stream's full extent by
      // [_frameStream] once tiles load. setCamera applies pitch; flyTo doesn't.
      await map.setCamera(CameraOptions(
        center: Point(coordinates: Position(widget.lon, widget.lat)),
        zoom: 14.0,
        pitch: 56.0,
        bearing: 18.0,
      ));
    } catch (e) {
      AppLogger.error('StreamMapSheet', 'Failed to add stream layers', e);
    }
  }

  /// Once tiles load, find this reach's geometry and frame the camera to its
  /// full extent (pitched). Runs once; if the reach isn't in the loaded tiles
  /// the coordinate-centred view from [_onStyleLoaded] stays.
  Future<void> _frameStream() async {
    final map = _map;
    if (map == null || _framed) return;
    _framed = true;
    try {
      final feats = await map.querySourceFeatures(
        _sourceId,
        SourceQueryOptions(
          sourceLayerIds: [_sourceLayer],
          filter: jsonEncode(_reachFilter),
        ),
      );
      Map<String?, Object?>? geometry;
      for (final f in feats) {
        final g = f?.queriedFeature.feature['geometry'];
        if (g is Map) {
          geometry = g.cast<String?, Object?>();
          break;
        }
      }
      if (geometry == null) return;
      final cam = await map.cameraForGeometry(
        geometry,
        MbxEdgeInsets(top: 70, left: 50, bottom: 70, right: 50),
        null,
        56.0,
      );
      final z = (cam.zoom ?? 14.0).clamp(11.0, 16.0);
      await map.setCamera(CameraOptions(
          center: cam.center, zoom: z, pitch: 56.0, bearing: 18.0));
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
