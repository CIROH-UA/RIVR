// lib/ui/2_presentation/features/map/pages/map_page.dart

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:rivr/ui/2_presentation/shared/widgets/navigation_button.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/2_presentation/routing/app_router.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/map_search_widget.dart';
// NEW IMPORTS
import 'package:rivr/ui/2_presentation/features/map/widgets/map_control_buttons.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/base_layer_modal.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/stream_source_modal.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/streams_list_bottom_sheet.dart'; // NEW: Import streams list
import 'package:rivr/services/4_infrastructure/map/map_controls_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_preference_service.dart';
// EXISTING IMPORTS
import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_cache_service.dart';
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/0_config/shared/constants.dart';
import 'package:rivr/services/4_infrastructure/map/map_vector_tiles_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_reach_selection_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_marker_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_service_factory.dart';
import 'package:rivr/services/4_infrastructure/map/stream_conditions_service.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/condition_legend.dart';
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';
// UPDATED: Import the optimized bottom sheet
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_details_bottom_sheet.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => MapPageState();
}

class MapPageState extends State<MapPage> {
  late final MapVectorTilesService _vectorTilesService;
  late final MapReachSelectionService _reachSelectionService;
  late final MapMarkerService _markerService;
  late final MapControlsService _controlsService;
  final StreamConditionsService _conditionsService = StreamConditionsService();

  // Flood-condition coloring, resolved from whatever region is on screen.
  // [_appliedConditions] accumulates station-id -> category across the VPUs the
  // user visits (so panning back keeps colors); [_appliedVpus] tracks which
  // regions we've already fetched; [_stationVpu] caches a reach -> VPU so a
  // known reach never triggers a second lookup.
  final Map<int, int> _appliedConditions = {};
  final Set<int> _appliedVpus = {};
  final Map<int, int> _stationVpu = {};
  bool _conditionsInFlight = false;
  bool _colorByCondition = MapPreferenceService.colorByConditionDefault;

  // NWM (US) coloring is per-reach (no region concept): classify the reaches on
  // screen, accumulating results so panning only ever asks about new reaches.
  final Map<int, int> _appliedNwmConditions = {};
  final Set<int> _resolvedNwmIds = {};
  bool _nwmInFlight = false;

  bool _isLoading = true;
  String? _errorMessage;
  MapboxMap? _mapboxMap;

  // Restored camera position (loaded before first build)
  ({double lat, double lng, double zoom})? _savedCamera;

  // Which stream networks are drawn (persisted; Auto default until loaded).
  StreamLayerVisibility _streamLayers = StreamLayerVisibility.defaults;

  @override
  void initState() {
    super.initState();
    final factory = GetIt.I<MapServiceFactory>();
    _vectorTilesService = factory.createVectorTilesService();
    _reachSelectionService = factory.createReachSelectionService();
    _markerService = factory.createMarkerService();
    _controlsService = factory.createControlsService();
    _setupSelectionCallbacks();
    _initializeCacheService();
    _loadSavedCamera();
    _loadStreamLayerPrefs();
  }

  /// Re-apply any colors we've already computed (a style reload wipes the
  /// layers), then fetch conditions for whatever region is now on screen.
  Future<void> _refreshConditionsAfterLoad() async {
    if (!_colorByCondition) return;
    // A style reload rebuilds the layers at full opacity — re-dim them.
    await _vectorTilesService.setBaseStreamsDimmed(true);
    if (_appliedConditions.isNotEmpty) {
      await _vectorTilesService.applyGeoglowsConditions(_appliedConditions);
    }
    if (_appliedNwmConditions.isNotEmpty) {
      await _vectorTilesService.applyNwmConditions(_appliedNwmConditions);
    }
    await _maybeColorVisibleRegion();
    await _maybeColorVisibleNwm();
  }

  /// Color the NWM (US) reaches on screen by flood condition: classify only the
  /// ones we haven't seen yet, accumulate, and paint. Best-effort.
  ///
  /// Skipped when zoomed out past [AppConfig.minZoomForVectorTiles]. NWM
  /// coloring is per-reach and capped at 800 ids per pass — against 2.78M
  /// reaches that can't meaningfully fill a regional view, so out there it is
  /// all cost (a large source query, an 800-id round trip, and a re-encode of
  /// an ever-growing match expression) for no visible payoff. GEOGLOWS keeps
  /// running at every zoom because it resolves a whole VPU at once.
  Future<void> _maybeColorVisibleNwm() async {
    if (!_colorByCondition || _nwmInFlight) return;

    final zoom = await _vectorTilesService.getCurrentZoom();
    if (zoom != null && zoom < AppConfig.minZoomForVectorTiles) return;

    final ids = await _vectorTilesService.visibleNwmStationIds();
    final unresolved =
        ids.where((id) => !_resolvedNwmIds.contains(id)).toList();
    if (unresolved.isEmpty || !mounted) return;

    _nwmInFlight = true;
    try {
      final conditions =
          await _conditionsService.fetchNwmByStations(unresolved);
      if (!mounted) return;
      _resolvedNwmIds.addAll(unresolved);
      if (conditions.isNotEmpty) {
        _appliedNwmConditions.addAll(conditions);
        await _vectorTilesService.applyNwmConditions(_appliedNwmConditions);
      }
    } finally {
      _nwmInFlight = false;
    }
  }

  /// Turn condition coloring on/off — persist the choice, then either paint the
  /// current region or reset the streams to their base color.
  Future<void> _setColorByCondition(bool enabled) async {
    setState(() => _colorByCondition = enabled);
    await MapPreferenceService.saveColorByCondition(enabled);
    // Hold the normal network back while coloring is on so elevated reaches
    // read as foreground; restore full opacity when it's off.
    await _vectorTilesService.setBaseStreamsDimmed(enabled);
    if (enabled) {
      if (_appliedConditions.isNotEmpty) {
        await _vectorTilesService.applyGeoglowsConditions(_appliedConditions);
      }
      if (_appliedNwmConditions.isNotEmpty) {
        await _vectorTilesService.applyNwmConditions(_appliedNwmConditions);
      }
      await _maybeColorVisibleRegion();
      await _maybeColorVisibleNwm();
    } else {
      await _vectorTilesService.clearGeoglowsConditions();
      await _vectorTilesService.clearNwmConditions();
    }
  }

  /// Color the region currently on screen: resolve its VPU from a visible reach,
  /// fetch that region's flood conditions once, and paint them. Accumulates
  /// across regions so revisiting is instant. Best-effort — silent on failure.
  Future<void> _maybeColorVisibleRegion() async {
    if (!_colorByCondition || _conditionsInFlight || !mounted) return;
    final size = MediaQuery.of(context).size;
    final sid = await _vectorTilesService.firstVisibleGeoglowsStationId(
      screenWidth: size.width,
      screenHeight: size.height,
    );
    if (sid == null || !mounted) return;

    // Already know this reach's region and have it painted? Nothing to do.
    final knownVpu = _stationVpu[sid];
    if (knownVpu != null && _appliedVpus.contains(knownVpu)) return;

    _conditionsInFlight = true;
    try {
      final res = await _conditionsService.fetchByStation(sid);
      if (res == null || !mounted) return;
      _stationVpu[sid] = res.vpu;
      if (!_appliedVpus.add(res.vpu)) return; // region already applied
      _appliedConditions.addAll(res.conditions);
      await _vectorTilesService.applyGeoglowsConditions(_appliedConditions);
    } finally {
      _conditionsInFlight = false;
    }
  }

  /// Load the persisted stream-network toggles for the modal's initial state.
  /// The authoritative apply-to-map happens in [_loadLayersAfterStyleReady].
  Future<void> _loadStreamLayerPrefs() async {
    final layers = await MapPreferenceService.loadStreamLayers();
    final colorByCondition = await MapPreferenceService.loadColorByCondition();
    if (mounted) {
      setState(() {
        _streamLayers = layers;
        _colorByCondition = colorByCondition;
      });
    }
  }

  /// Load last camera position from storage before first build
  Future<void> _loadSavedCamera() async {
    final saved = await MapControlsService.loadLastCameraPosition();
    if (saved != null && mounted) {
      setState(() => _savedCamera = saved);
    }
  }

  @override
  void dispose() {
    // Save camera position before tearing down (fire-and-forget)
    _controlsService.saveLastCameraPosition();
    _vectorTilesService.dispose();
    _markerService.dispose();
    _controlsService.dispose();
    super.dispose();
  }

  void _setupSelectionCallbacks() {
    _reachSelectionService.onReachSelected = _onReachSelected;
    _reachSelectionService.onEmptyTap = _onEmptyTap;
  }

  /// Initialize cache service for recent searches and other caching needs
  Future<void> _initializeCacheService() async {
    try {
      await GetIt.I<ICacheService>().initialize();
      AppLogger.info('MapPage', 'Cache service initialized for recent searches');
    } catch (e) {
      AppLogger.error('MapPage', 'Cache service initialization error', e);
      // Don't fail the whole page if cache fails - search will still work
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(child: _buildMapContent());
  }

  Widget _buildMapContent() {
    if (_errorMessage != null) {
      return _buildError();
    }

    return Stack(
      children: [
        // Clean map widget without Consumer wrapper
        _buildMap(),

        // Search bar at bottom using SafeArea
        Positioned(
          bottom: 30,
          left: 0,
          right: 0,
          child: SafeArea(
            child: CompactMapSearchBar(onTap: () => _showSearchModal()),
          ),
        ),

        // Floating back button positioned in top-left
        Positioned(
          top: 30,
          left: 0,
          child: FloatingBackButton(
            backgroundColor: CupertinoColors.white.withValues(alpha: 0.95),
            iconColor: CupertinoColors.systemBlue,
            margin: const EdgeInsets.only(top: 8, left: 16),
          ),
        ),

        // Map control buttons in top-right
        Positioned(
          top: 60,
          right: 0,
          child: SafeArea(
            child: Container(
              margin: const EdgeInsets.only(top: 8, right: 16),
              child: MapControlButtons(
                onLayersPressed: _showLayersModal,
                onSourcesPressed: _showStreamSourceModal,
                onStreamsPressed: _showStreamsModal,
                onRecenterPressed: _recenterToLocation,
                on3DTogglePressed: _toggle3DTerrain,
                is3DEnabled: _controlsService.is3DEnabled,
                is3DAvailable: _controlsService.supports3D,
              ),
            ),
          ),
        ),

        // Flood-risk color key — shown whenever coloring is on. Streams render
        // at every zoom now, so this stays up when zoomed out too, where the
        // regional GEOGLOWS coloring is most worth explaining.
        if (_colorByCondition)
          Positioned(
            left: 16,
            bottom: 96,
            child: SafeArea(child: const ConditionLegend()),
          ),

        if (_isLoading) _buildLoadingOverlay(),
      ],
    );
  }


  /// Toggle 3D terrain on/off
  Future<void> _toggle3DTerrain() async {
    await _controlsService.toggle3DTerrain();
    setState(() {}); // Refresh UI to update button state
  }

  Widget _buildMap() {
    final cam = _savedCamera;
    return MapWidget(
      cameraOptions: CameraOptions(
        center: Point(
          coordinates: Position(
            cam?.lng ?? AppConfig.defaultLongitude,
            cam?.lat ?? AppConfig.defaultLatitude,
          ),
        ),
        zoom: cam?.zoom ?? AppConfig.defaultZoom,
      ),
      styleUri: AppConstants.defaultMapboxStyleUrl,
      textureView: true,
      onMapCreated: _onMapCreated,
      onTapListener: _onMapTap,
      onStyleLoadedListener: _onStyleLoaded,
      onMapIdleListener: _onMapIdle,
    );
  }

  /// Save camera position when the map stops moving, then color what the user
  /// settled on. Streams no longer show/hide with zoom, so there is no
  /// visibility to reconcile here.
  void _onMapIdle(MapIdleEventData data) {
    _controlsService.saveLastCameraPosition();
    // Color whatever the user just settled on (no-op if already colored or no
    // streams are in view) — GEOGLOWS by region, NWM by visible reach.
    unawaited(_maybeColorVisibleRegion());
    unawaited(_maybeColorVisibleNwm());
  }


  Widget _buildLoadingOverlay() {
    return Container(
      color: CupertinoColors.systemBackground.withValues(alpha: 0.8),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CupertinoActivityIndicator(radius: 16),
            SizedBox(height: 16),
            Text(
              'Loading river map...',
              style: TextStyle(fontSize: 16, color: CupertinoColors.systemGrey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 48,
              color: CupertinoColors.systemRed,
              semanticLabel: 'Map error',
            ),
            const SizedBox(height: 16),
            const Text(
              'Map Error',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: CupertinoColors.systemGrey,
              ),
            ),
            const SizedBox(height: 24),
            CupertinoButton.filled(
              onPressed: _retryMapLoad,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;

    try {
      AppLogger.debug('MapPage', 'Map created, initializing...');

      // Initialize core map services
      _vectorTilesService.setMapboxMap(mapboxMap);
      _reachSelectionService.setMapboxMap(mapboxMap);
      _controlsService.setMapboxMap(mapboxMap);

      // Initialize map style based on preferences
      await _controlsService.initializeMapStyle();

      AppLogger.debug('MapPage', 'Services initialized, waiting for style to load...');

      // Start location initialization (does not depend on style being loaded)
      _controlsService.initializeLocation().then((position) {
        // On first visit (no saved camera), fly to device location
        if (_savedCamera == null && position != null && mounted) {
          _controlsService.recenterToDeviceLocation();
          AppLogger.info('MapPage', 'First visit — centered on device location');
        }
      });

      // Vector tiles, markers, and terrain are loaded in _onStyleLoaded
      // to ensure the map style is fully ready before adding layers.
    } catch (e) {
      AppLogger.error('MapPage', 'Map creation error', e);
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load river data: ${e.toString()}';
      });
    }
  }

  /// Called automatically when map style finishes loading.
  /// Loads vector tiles, markers, and 3D terrain on every style load
  /// (initial + style changes) so layers are always added to a ready style.
  void _onStyleLoaded(StyleLoadedEventData data) {
    _loadLayersAfterStyleReady();
  }

  /// Load vector tiles and markers after the style is fully ready.
  /// Called on every style load (initial and subsequent style changes).
  Future<void> _loadLayersAfterStyleReady() async {
    try {
      AppLogger.debug('MapPage', 'Style loaded, loading vector tiles...');

      // Apply lightPreset for Standard style (handles initial load + basemap changes)
      await _controlsService.applyLightPreset();

      // Reset vector tiles state (safe for both initial and subsequent loads)
      _vectorTilesService.dispose();
      _vectorTilesService.setMapboxMap(_mapboxMap!);

      // Load vector tiles
      await _vectorTilesService.loadRiverReaches();

      // Restore the saved stream-network toggles onto the freshly loaded layers.
      final streamLayers = await MapPreferenceService.loadStreamLayers();
      if (mounted) setState(() => _streamLayers = streamLayers);
      await _vectorTilesService.applyStreamVisibility(
        nwm: streamLayers.nwm,
        geoglowsWorld: streamLayers.geoglowsWorld,
        geoglowsUs: streamLayers.geoglowsUs,
      );

      // Pre-color GEOGLOWS streams by current flood condition. Fetched off the
      // critical path (the backend read can take up to ~90s cold) — streams
      // render immediately and recolor when the conditions arrive.
      unawaited(_refreshConditionsAfterLoad());

      // Initialize markers on top of vector tiles (correct z-ordering)
      await _markerService.initializeMarkers(_mapboxMap!);

      // Apply 3D terrain if enabled
      _controlsService.applyTerrainIfEnabled();

      // Complete initial loading if this is the first style load
      if (_isLoading) {
        setState(() {
          _isLoading = false;
        });
        AppLogger.info('MapPage', 'Map setup complete');
      } else {
        AppLogger.info('MapPage', 'Vector tiles reloaded after style change');
      }
    } catch (e) {
      AppLogger.error('MapPage', 'Error loading layers after style ready', e);
      if (_isLoading) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load river data: ${e.toString()}';
        });
      }
    }
  }

  void _showSearchModal() {
    if (_mapboxMap == null) {
      AppLogger.warning('MapPage', 'Map not ready for search');
      return;
    }

    showMapSearchModal(
      context,
      mapboxMap: _mapboxMap,
      onPlaceSelected: (place) {
        AppLogger.debug(
          'MapPage',
          'Selected place: ${place.shortName} at ${place.latitude}, ${place.longitude}',
        );
      },
    );
  }

  // NEW: Show layers modal
  void _showLayersModal() {
    showBaseLayerModal(
      context,
      currentLayer: _controlsService.currentLayer,
      onLayerSelected: (layer) async {
        await _controlsService.changeBaseLayer(layer);
        setState(() {}); // Refresh UI to update 3D button state
        AppLogger.debug('MapPage', 'Layer changed to: ${layer.displayName}');
      },
    );
  }

  // Show the stream-source (NWM / GEOGLOWS) toggle modal.
  void _showStreamSourceModal() {
    showStreamSourceModal(
      context,
      initial: _streamLayers,
      colorByCondition: _colorByCondition,
      onColorByConditionChanged: _setColorByCondition,
      onChanged: (layers) async {
        setState(() => _streamLayers = layers);
        await _vectorTilesService.applyStreamVisibility(
          nwm: layers.nwm,
          geoglowsWorld: layers.geoglowsWorld,
          geoglowsUs: layers.geoglowsUs,
        );
        await MapPreferenceService.saveStreamLayers(layers);
        AppLogger.debug(
          'MapPage',
          'Stream layers: NWM=${layers.nwm} '
              'GEOGLOWS_world=${layers.geoglowsWorld} '
              'GEOGLOWS_us=${layers.geoglowsUs}',
        );
      },
    );
  }

  // NEW: Show streams modal
  void _showStreamsModal() async {
    if (_mapboxMap == null) {
      AppLogger.warning('MapPage', 'Map not ready for streams list');
      return;
    }

    try {
      // Get visible streams using actual screen dimensions
      final size = MediaQuery.of(context).size;
      final visibleStreams = await _reachSelectionService.getVisibleStreams(
        screenWidth: size.width,
        screenHeight: size.height,
      );

      if (!mounted) return;

      if (visibleStreams.isEmpty) {
        // Show feedback if no streams are visible
        _showNoStreamsAlert();
        return;
      }

      // Show the streams list bottom sheet
      showStreamsListModal(
        context,
        streams: visibleStreams,
        onStreamSelected: (stream) async {
          // Fly to the selected stream and highlight it
          await _reachSelectionService.flyToStream(stream);
          AppLogger.debug('MapPage', 'Flying to stream: ${stream.stationId}');
        },
      );
    } catch (e) {
      AppLogger.error('MapPage', 'Error showing streams modal', e);
    }
  }

  // Helper method to show alert when no streams are visible
  void _showNoStreamsAlert() {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('No Streams Visible'),
        content: const Text(
          'Zoom in or pan the map to see streams in the current view.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  // NEW: Recenter to device location
  void _recenterToLocation() async {
    await _controlsService.recenterToDeviceLocation();
  }

  Future<void> _onMapTap(MapContentGestureContext context) async {
    // Tappable at any zoom. Taps used to be blocked below
    // minZoomForVectorTiles, back when every order band drew down there and
    // order-1 creeks simplified into dots nobody could hit. Now only order 5+
    // renders when zoomed out — big rivers, the geometry that survives
    // simplification best — so refusing the query was blocking taps on the
    // one thing clearly visible. A tap that finds nothing falls through to
    // onEmptyTap, which is all the feedback it needs.
    await _reachSelectionService.handleMapTap(context);
  }

  // UPDATED: Call bottom sheet directly without helper function
  void _onReachSelected(SelectedReach selectedReach) {
    // Highlight the tapped stream and lift it into view above the sheet.
    _reachSelectionService.highlightSelectedReach();
    _focusCameraOnReach(selectedReach);

    showCupertinoModalPopup(
      context: context,
      builder: (context) => ReachDetailsBottomSheet(
        selectedReach: selectedReach,
        onViewForecast: () => _navigateToForecast(selectedReach),
        // Recolor the map highlight from gold to the flood-category color once
        // the sheet has classified the flow.
        onFlowCategoryColor: (argb) =>
            _reachSelectionService.recolorHighlight(argb),
      ),
    ).then((_) async {
      // Sheet dismissed: drop the highlight and restore the camera padding.
      await _reachSelectionService.clearLineHighlight();
      await _resetCameraPadding();
    });
  }

  /// Slide the map so the tapped stream sits in the strip above the details
  /// sheet, keeping the user's current zoom. Bottom padding equal to the sheet's
  /// height shifts the reach up into the visible area.
  Future<void> _focusCameraOnReach(SelectedReach reach) async {
    final map = _mapboxMap;
    if (map == null) return;
    try {
      final cam = await map.getCameraState();
      if (!mounted) return;
      final sheetPad = MediaQuery.of(context).size.height * 0.52;
      await map.flyTo(
        CameraOptions(
          center: Point(
            coordinates: Position(reach.longitude, reach.latitude),
          ),
          zoom: cam.zoom,
          padding: MbxEdgeInsets(top: 0, left: 0, bottom: sheetPad, right: 0),
        ),
        MapAnimationOptions(duration: 700, startDelay: 0),
      );
    } catch (e) {
      AppLogger.error('MapPage', 'Error focusing camera on reach', e);
    }
  }

  /// Clear the bottom camera padding applied while the sheet was open.
  Future<void> _resetCameraPadding() async {
    final map = _mapboxMap;
    if (map == null) return;
    try {
      await map.setCamera(
        CameraOptions(padding: MbxEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)),
      );
    } catch (_) {}
  }

  void _onEmptyTap(Point point) {
    // Could add feedback here if needed
    // For now, just let any open bottom sheet stay open
  }

  void _navigateToForecast(SelectedReach selectedReach) {
    Navigator.of(context).pop(); // Close bottom sheet

    // Navigate to forecast page with reachId + source (NWM vs GEOGLOWS).
    AppRouter.pushForecast(
      context,
      reachId: selectedReach.reachId,
      source: selectedReach.source,
      lat: selectedReach.latitude,
      lon: selectedReach.longitude,
    );
  }

  void _retryMapLoad() {
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    // Reset services and retry
    _vectorTilesService.dispose();
    _markerService.dispose();
    _controlsService.dispose(); // NEW: Reset controls service too

    // Map will be recreated and _onMapCreated will be called again
  }

  // NEW: Expose marker service for wrapper widget
  MapMarkerService get markerService => _markerService;
}
