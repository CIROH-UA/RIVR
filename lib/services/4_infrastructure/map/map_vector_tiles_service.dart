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

  /// The base color of a normal (not above-normal) reach. Deliberately shared
  /// by NWM and GEOGLOWS: the flood-risk legend describes conditions, not data
  /// sources, so "Normal" has to look the same whichever network drew the line.
  /// Source is still distinguishable in the Stream Data sheet and on tap.
  static const int _streamColor = 0xFF191970; // Midnight blue

  /// The three stream-order bands every network is split into. Layers are per
  /// band so each can carry its own width; the band is also what [_widthFor]
  /// keys off, which is what keeps NWM and GEOGLOWS identically thick.
  static const int _bandSmall = 0; // stream order 1-2
  static const int _bandMedium = 1; // stream order 3-4
  static const int _bandLarge = 2; // stream order 5+

  /// Line width per (band, zoom). One table, used by every stream layer of
  /// every network — previously these were nine hardcoded constants that
  /// happened to agree, with nothing enforcing that they stay in step.
  ///
  /// Width also has to vary with zoom now that streams render at every zoom.
  /// Fixed widths made a continental view a solid hairball and a street-level
  /// view look anaemic; these taper to hairlines when zoomed out and thicken
  /// up close. The z10 row is the old fixed set, so mid zooms look unchanged.
  static const List<int> _widthStops = [3, 7, 10, 14];
  static const Map<int, List<double>> _widthByBand = {
    _bandSmall: [0.4, 0.8, 1.0, 2.0],
    _bandMedium: [0.7, 1.4, 2.0, 3.5],
    _bandLarge: [1.2, 2.2, 3.5, 6.0],
  };

  /// A `line-width` expression interpolating [_widthByBand] over zoom.
  /// [scale]/[floor] widen a line relative to the shared curve while keeping
  /// its shape — used by the condition-highlight layers so an above-normal
  /// reach stays proportionally thicker at every zoom (see [_highlightLayer]).
  static List<Object> _widthFor(int band, {double scale = 1.0, double floor = 0}) {
    final widths = _widthByBand[band]!;
    final expr = <Object>[
      'interpolate',
      ['linear'],
      ['zoom'],
    ];
    for (var i = 0; i < _widthStops.length; i++) {
      final w = widths[i];
      expr.add(_widthStops[i]);
      // A pure multiplier vanishes where the base is already sub-pixel, so
      // also guarantee a minimum absolute gain.
      expr.add(scale == 1.0 ? w : _maxOf(w * scale, w + floor));
    }
    return expr;
  }

  static double _maxOf(double a, double b) => a > b ? a : b;

  /// Zoom at which each order band starts drawing.
  ///
  /// The tileset decides what data is *in* a tile; this decides what we draw
  /// from it. Without these every band rendered at every zoom, so a
  /// continental view drew millions of order-1 creeks as sub-pixel hairlines —
  /// invisible, but still filtered and rasterized every frame. Big rivers
  /// carry the shape of the network when zoomed out; the small stuff only
  /// starts to mean something up close. This is how HydroViewer reads.
  ///
  /// It also cuts the cost of the US mask, which only runs on features a layer
  /// actually considers (see [_usMaskGeometry]).
  ///
  /// Highlight layers are deliberately exempt — an above-normal creek should
  /// show at any zoom, which is the whole point of the feature.
  static const Map<int, double> _minZoomByBand = {
    _bandSmall: 9.0, // order 1-2
    _bandMedium: 7.0, // order 3-4
    _bandLarge: 0.0, // order 5+ — always drawn
  };

  /// Normal opacity per band — the values the stream layers are built with.
  static const Map<int, double> _opacityByBand = {
    _bandSmall: 0.8,
    _bandMedium: 0.8,
    _bandLarge: 0.9,
  };

  /// Opacity for normal reaches while condition coloring is on. Holding the
  /// base network back makes the above-normal reaches read as foreground
  /// without touching their own styling — contrast does the work.
  static const double _dimmedOpacity = 0.45;

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

  /// Condition-highlight layers — one per network per order band, mirroring the
  /// base layers and added *after* them so they paint last.
  ///
  /// These exist for draw order. Coloring alone rides `line-color` on the base
  /// layers, so an Extreme order-2 creek paints underneath a normal order-6
  /// river: Mapbox draws per layer, in layer order, and no amount of width or
  /// color fixes that. Above-normal reaches are re-drawn here, on top of
  /// everything, wider than the base curve.
  ///
  /// Ids keep the `geoglows` prefix rule that [ForecastSource.fromLayerIds]
  /// depends on — anything not so prefixed resolves to NWM.
  static const List<String> _nwmHighlightLayerIds = [
    'streams2-hl-order-1-2',
    'streams2-hl-order-3-4',
    'streams2-hl-order-5-plus',
  ];
  static const List<String> _geoglowsWorldHighlightLayerIds = [
    'geoglows-hl-order-1-2',
    'geoglows-hl-order-3-4',
    'geoglows-hl-order-5-plus',
  ];
  static const List<String> _geoglowsUsHighlightLayerIds = [
    'geoglows-us-hl-order-1-2',
    'geoglows-us-hl-order-3-4',
    'geoglows-us-hl-order-5-plus',
  ];

  static const List<String> _allHighlightLayerIds = [
    ..._nwmHighlightLayerIds,
    ..._geoglowsWorldHighlightLayerIds,
    ..._geoglowsUsHighlightLayerIds,
  ];

  /// How much wider an above-normal reach is drawn than the base curve.
  static const double _highlightScale = 1.8;
  static const double _highlightFloor = 1.0;

  /// The stream-order filter for each band, matching the base layers.
  static List<Object> _orderFilterFor(int band) => switch (band) {
    _bandSmall => [
      '<=',
      ['get', 'streamOrder'],
      2,
    ],
    _bandMedium => [
      'all',
      [
        '>=',
        ['get', 'streamOrder'],
        3,
      ],
      [
        '<=',
        ['get', 'streamOrder'],
        4,
      ],
    ],
    _ => [
      '>=',
      ['get', 'streamOrder'],
      5,
    ],
  };

  /// Restrict a layer to an explicit set of reaches. An empty [stationIds]
  /// yields a filter that matches nothing — the natural "no conditions" state.
  static List<Object> _stationIdFilter(Iterable<int> stationIds) => [
    'in',
    ['get', 'station_id'],
    ['literal', stationIds.toList()],
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

      // Above-normal reaches are re-drawn on top of every base layer, so they
      // must be added last. They start empty and fill in as conditions arrive.
      await _addHighlightLayers();

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
    await _setLayerGroupVisibility(_nwmHighlightLayerIds, visible);
  }

  /// Set GEOGLOWS "outside the US" stream visibility.
  Future<void> setGeoglowsWorldVisible(bool visible) async {
    _geoglowsWorldVisible = visible;
    await _setLayerGroupVisibility(_geoglowsWorldLayerIds, visible);
    await _setLayerGroupVisibility(_geoglowsWorldHighlightLayerIds, visible);
  }

  /// Set GEOGLOWS "US area" stream visibility (off by default — overlaps NWM).
  Future<void> setGeoglowsUsVisible(bool visible) async {
    _geoglowsUsVisible = visible;
    await _setLayerGroupVisibility(_geoglowsUsLayerIds, visible);
    await _setLayerGroupVisibility(_geoglowsUsHighlightLayerIds, visible);
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
          lineWidthExpression: _widthFor(_bandSmall),
          minZoom: _minZoomByBand[_bandSmall],
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
          lineWidthExpression: _widthFor(_bandMedium),
          minZoom: _minZoomByBand[_bandMedium],
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
          lineWidthExpression: _widthFor(_bandLarge),
          minZoom: _minZoomByBand[_bandLarge],
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
  /// Mirrors the NWM layer styling — same base [_streamColor], so normal
  /// reaches look identical across sources — with `geoglows-*` layer ids that
  /// drive source-routing on tap.
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
          lineColor: _streamColor,
          lineWidthExpression: _widthFor(_bandSmall),
          minZoom: _minZoomByBand[_bandSmall],
          lineOpacity: 0.8,
          filter: _outsideUs(["<=", ["get", "streamOrder"], 2]),
        ),
      );
      await _mapboxMap!.style.addLayer(
        LineLayer(
          id: 'geoglows-order-3-4',
          sourceId: AppConfig.geoglowsSourceId,
          sourceLayer: AppConfig.geoglowsSourceLayer,
          lineColor: _streamColor,
          lineWidthExpression: _widthFor(_bandMedium),
          minZoom: _minZoomByBand[_bandMedium],
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
          lineColor: _streamColor,
          lineWidthExpression: _widthFor(_bandLarge),
          minZoom: _minZoomByBand[_bandLarge],
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
          lineColor: _streamColor,
          lineWidthExpression: _widthFor(_bandSmall),
          minZoom: _minZoomByBand[_bandSmall],
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
          lineColor: _streamColor,
          lineWidthExpression: _widthFor(_bandMedium),
          minZoom: _minZoomByBand[_bandMedium],
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
          lineColor: _streamColor,
          lineWidthExpression: _widthFor(_bandLarge),
          minZoom: _minZoomByBand[_bandLarge],
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

  // --- condition coloring ----------------------------------------------------
  //
  // Data-drive line-color on the EXISTING vector layers by station_id, so an
  // above-normal reach shows yellow/orange/red/purple without re-tiling. The
  // color is a `match` expression keyed on station_id: only listed reaches
  // recolor, everything else keeps the base color. Validated on device — a
  // 10k-entry expression applies in ~34ms with no render lag — so a single
  // global blob of above-normal reaches is viable (no viewport chunking needed).
  // The map of elevated reaches comes from the backend (computed peak vs return
  // periods); this method just paints it.

  /// Category index (1..4) -> hex line color, matching the forecast gauge.
  /// 0 (Normal) is intentionally absent — normal reaches keep the base color.
  static const Map<int, String> _categoryColors = {
    1: '#FFC400', // Action   — yellow
    2: '#FF8C00', // Moderate — orange
    3: '#E53935', // Major    — red
    4: '#8E24AA', // Extreme  — purple
  };

  static String _hex(int argb) {
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  /// Apply per-reach condition colors to [layerIds] as a `match` expression on
  /// `station_id`. [categoryByStationId] maps a reach's numeric station id to a
  /// category index (1..4); anything not listed falls through to [baseColor].
  Future<void> applyConditionColors(
    Map<int, int> categoryByStationId, {
    required List<String> layerIds,
    required int baseColor,
  }) async {
    if (_mapboxMap == null) return;

    final encoded = json.encode(
      _conditionColorExpression(categoryByStationId, baseColor),
    );
    for (final layerId in layerIds) {
      try {
        await _mapboxMap!.style.setStyleLayerProperty(
          layerId,
          'line-color',
          encoded,
        );
      } catch (e) {
        AppLogger.warning(
          'MapVectorTilesService',
          'applyConditionColors failed for $layerId: $e',
        );
      }
    }
  }

  /// Side of the centered screen box used to find one on-screen GEOGLOWS reach.
  /// Small on purpose — see [firstVisibleGeoglowsStationId].
  static const double _probeBoxSide = 160;

  /// The station id of some GEOGLOWS reach on screen — used to resolve which
  /// region (VPU) to fetch conditions for. Null when nothing is under the
  /// probe (e.g. inside the US, or open ocean at the center of the map).
  ///
  /// This deliberately uses a *rendered* query over a small box at the center
  /// rather than a source query. `querySourceFeatures` returns every feature in
  /// every loaded tile and serializes the lot across the platform channel —
  /// fine at a city zoom (~23-36 reaches), but it grows without bound as you
  /// zoom out and was the main cost of drawing streams at low zoom. We only
  /// ever need *one* reach to identify the region, so a small bounded probe is
  /// enough. A miss just means no new region resolves this idle; the next pan
  /// or zoom retries, and callers already handle null.
  /// [screenWidth]/[screenHeight] come from the caller's MediaQuery —
  /// MapboxMap.getSize() is unimplemented on iOS and throws unconditionally.
  Future<int?> firstVisibleGeoglowsStationId({
    required double screenWidth,
    required double screenHeight,
  }) async {
    final map = _mapboxMap;
    if (map == null) return null;
    try {
      final cx = screenWidth / 2;
      final cy = screenHeight / 2;
      final half = _probeBoxSide / 2;

      final feats = await map.queryRenderedFeatures(
        RenderedQueryGeometry.fromScreenBox(
          ScreenBox(
            min: ScreenCoordinate(x: cx - half, y: cy - half),
            max: ScreenCoordinate(x: cx + half, y: cy + half),
          ),
        ),
        RenderedQueryOptions(layerIds: _geoglowsWorldLayerIds),
      );
      for (final f in feats) {
        final props = f?.queriedFeature.feature['properties'];
        final sid = props is Map ? props['station_id'] : null;
        if (sid is int) return sid;
      }
    } catch (e) {
      AppLogger.warning(
        'MapVectorTilesService',
        'firstVisibleGeoglowsStationId failed: $e',
      );
    }
    return null;
  }

  /// Paint the GEOGLOWS "outside the US" stream layers by flood condition —
  /// [categoryByStationId] maps a reach's station id to a category (1..4), from
  /// [StreamConditionsService]. Above-normal reaches show their category color;
  /// everything else keeps the shared base color. Safe to call repeatedly.
  Future<void> applyGeoglowsConditions(
    Map<int, int> categoryByStationId,
  ) async {
    if (categoryByStationId.isEmpty) return;
    await applyConditionColors(
      categoryByStationId,
      layerIds: _geoglowsWorldLayerIds,
      baseColor: _streamColor,
    );
    await _applyHighlight(_geoglowsWorldHighlightLayerIds, categoryByStationId);
  }

  /// Reset the GEOGLOWS "outside the US" stream layers to their plain base color
  /// (used when the user turns condition coloring off).
  Future<void> clearGeoglowsConditions() async {
    await _resetLineColor(_geoglowsWorldLayerIds, _streamColor);
    await _applyHighlight(_geoglowsWorldHighlightLayerIds, const {});
  }

  /// Up to [limit] station ids of NWM (US) reaches currently loaded in view —
  /// the reaches to ask the backend to classify. Empty when no NWM streams are
  /// on screen (e.g. outside the US, or zoomed too far out).
  Future<List<int>> visibleNwmStationIds({int limit = 800}) async {
    final map = _mapboxMap;
    if (map == null) return const [];
    try {
      final feats = await map.querySourceFeatures(
        AppConfig.vectorSourceId,
        SourceQueryOptions(
          sourceLayerIds: [AppConfig.vectorSourceLayer],
          filter: '',
        ),
      );
      final ids = <int>{};
      for (final f in feats) {
        final props = f?.queriedFeature.feature['properties'];
        final sid = props is Map ? props['station_id'] : null;
        if (sid is int) {
          ids.add(sid);
          if (ids.length >= limit) break;
        }
      }
      return ids.toList();
    } catch (e) {
      AppLogger.warning(
        'MapVectorTilesService',
        'visibleNwmStationIds failed: $e',
      );
      return const [];
    }
  }

  /// `["match", ["get","station_id"], id, color, …, default]` — the mechanism
  /// behind all condition coloring (see ADR 0004). Shared by the base layers
  /// and the highlight layers so both read from one definition of the ladder.
  static List<Object> _conditionColorExpression(
    Map<int, int> categoryByStationId,
    int baseColor,
  ) {
    final expr = <Object>['match', ['get', 'station_id']];
    categoryByStationId.forEach((stationId, category) {
      final color = _categoryColors[category];
      if (color != null) {
        expr.add(stationId);
        expr.add(color);
      }
    });
    expr.add(_hex(baseColor)); // default
    return expr;
  }

  /// Add the condition-highlight layers for all three networks, on top of the
  /// base layers. They carry no reaches until [applyConditionColors] fills in
  /// a filter, so on a fresh load they render nothing.
  Future<void> _addHighlightLayers() async {
    Future<void> add(
      String id,
      String sourceId,
      String sourceLayer,
      int band,
      List<Object> filter,
    ) async {
      try {
        await _mapboxMap!.style.addLayer(
          LineLayer(
            id: id,
            sourceId: sourceId,
            sourceLayer: sourceLayer,
            lineColor: _streamColor,
            lineWidthExpression: _widthFor(
              band,
              scale: _highlightScale,
              floor: _highlightFloor,
            ),
            lineOpacity: 1.0,
            lineCap: LineCap.ROUND,
            filter: filter,
          ),
        );
      } catch (e) {
        AppLogger.warning('MapVectorTilesService', 'Failed to add $id: $e');
      }
    }

    final none = _stationIdFilter(const []);
    for (var band = 0; band < 3; band++) {
      final order = _orderFilterFor(band);
      // No US mask here, unlike the base layers: the station-id filter already
      // scopes these to reaches the backend classified, and `within` against a
      // 381-vertex boundary is far too expensive to run per feature on layers
      // that exist only to re-draw a handful of them. The id filter also comes
      // first so `all` short-circuits on it.
      await add(
        _nwmHighlightLayerIds[band],
        AppConfig.vectorSourceId,
        AppConfig.vectorSourceLayer,
        band,
        ['all', none, order],
      );
      await add(
        _geoglowsWorldHighlightLayerIds[band],
        AppConfig.geoglowsSourceId,
        AppConfig.geoglowsSourceLayer,
        band,
        ['all', none, order],
      );
      await add(
        _geoglowsUsHighlightLayerIds[band],
        AppConfig.geoglowsSourceId,
        AppConfig.geoglowsSourceLayer,
        band,
        ['all', none, order],
      );
    }
    AppLogger.info('MapVectorTilesService', 'Added condition-highlight layers');
  }

  /// Point a network's highlight layers at [categoryByStationId]: restrict them
  /// to those reaches and color each by its category. Empty clears them.
  Future<void> _applyHighlight(
    List<String> highlightLayerIds,
    Map<int, int> categoryByStationId,
  ) async {
    if (_mapboxMap == null) return;
    final idFilter = _stationIdFilter(categoryByStationId.keys);
    final colorExpr = json.encode(
      _conditionColorExpression(categoryByStationId, _streamColor),
    );

    for (var band = 0; band < highlightLayerIds.length; band++) {
      final layerId = highlightLayerIds[band];
      // Id filter first — `all` short-circuits, and it is the selective one.
      final filter = json.encode([
        'all',
        idFilter,
        _orderFilterFor(band),
      ]);
      try {
        await _mapboxMap!.style.setStyleLayerProperty(
          layerId,
          'filter',
          filter,
        );
        await _mapboxMap!.style.setStyleLayerProperty(
          layerId,
          'line-color',
          colorExpr,
        );
      } catch (e) {
        AppLogger.warning(
          'MapVectorTilesService',
          '_applyHighlight failed for $layerId: $e',
        );
      }
    }
  }

  /// Hold the normal stream network back (or restore it) so above-normal
  /// reaches read as foreground. Called when condition coloring is toggled.
  /// Band is positional: every layer-id list is ordered small, medium, large.
  Future<void> setBaseStreamsDimmed(bool dimmed) async {
    if (_mapboxMap == null) return;
    for (final ids in [
      _nwmLayerIds,
      _geoglowsWorldLayerIds,
      _geoglowsUsLayerIds,
    ]) {
      for (var band = 0; band < ids.length; band++) {
        final opacity = dimmed ? _dimmedOpacity : _opacityByBand[band]!;
        try {
          await _mapboxMap!.style.setStyleLayerProperty(
            ids[band],
            'line-opacity',
            opacity,
          );
        } catch (e) {
          // Layer might not exist yet, that's fine.
        }
      }
    }
  }

  /// Paint the NWM (US) stream layers by flood condition.
  Future<void> applyNwmConditions(Map<int, int> categoryByStationId) async {
    if (categoryByStationId.isEmpty) return;
    await applyConditionColors(
      categoryByStationId,
      layerIds: _nwmLayerIds,
      baseColor: _streamColor,
    );
    await _applyHighlight(_nwmHighlightLayerIds, categoryByStationId);
  }

  /// Reset the NWM stream layers to their plain base color.
  Future<void> clearNwmConditions() async {
    await _resetLineColor(_nwmLayerIds, _streamColor);
    await _applyHighlight(_nwmHighlightLayerIds, const {});
  }

  Future<void> _resetLineColor(List<String> layerIds, int baseColor) async {
    if (_mapboxMap == null) return;
    for (final layerId in layerIds) {
      try {
        await _mapboxMap!.style.setStyleLayerProperty(
          layerId,
          'line-color',
          _hex(baseColor),
        );
      } catch (e) {
        // Layer might not exist yet, that's fine.
      }
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
        ..._allHighlightLayerIds,
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

  // Stream visibility is no longer zoom-dependent. It used to be: streams were
  // hidden below AppConfig.minZoomForVectorTiles because the tileset's
  // low-zoom geometry renders as dots and can't be reliably tapped. But that
  // conflated two separate problems — "you can't tap this" and "you shouldn't
  // see this" — and hiding the streams also hid the flood-risk coloring at
  // exactly the scale where a regional view is most useful. Tappability is now
  // gated on its own in MapPage._onMapTap; rendering is purely the per-network
  // toggles. Both tilesets serve geometry far below that threshold (NWM z0-16,
  // GEOGLOWS z3-12), so there is real geometry to draw out there.

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
