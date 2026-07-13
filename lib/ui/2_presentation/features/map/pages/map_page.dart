// lib/ui/2_presentation/features/map/pages/map_page.dart

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

  bool _isLoading = true;
  String? _errorMessage;
  MapboxMap? _mapboxMap;

  // True when the map is zoomed out past the point where stream geometry is
  // usable (below AppConfig.minZoomForVectorTiles). Below this the tileset
  // serves over-simplified geometry that renders as dots and can't be reliably
  // tapped, so we hide the streams and show a "zoom in" hint instead.
  bool _showZoomHint = false;

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

  /// Load the persisted stream-network toggles for the modal's initial state.
  /// The authoritative apply-to-map happens in [_loadLayersAfterStyleReady].
  Future<void> _loadStreamLayerPrefs() async {
    final layers = await MapPreferenceService.loadStreamLayers();
    if (mounted) setState(() => _streamLayers = layers);
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

        // "Zoom in" hint shown while the map is too far out to see/tap streams.
        Positioned.fill(
          child: IgnorePointer(
            child: Center(child: _buildZoomHint()),
          ),
        ),

        if (_isLoading) _buildLoadingOverlay(),
      ],
    );
  }

  /// Non-blocking pill that fades in, centered on screen, when zoomed out past
  /// the usable stream range, telling the user to zoom in to see and tap rivers.
  Widget _buildZoomHint() {
    return AnimatedOpacity(
      opacity: _showZoomHint ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.black.withValues(alpha: 0.18),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.zoom_in,
              size: 20,
              color: CupertinoColors.systemBlue,
            ),
            SizedBox(width: 8),
            Text(
              'Zoom in to see and tap rivers',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label,
              ),
            ),
          ],
        ),
      ),
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

  /// Save camera position when the map stops moving, and reconcile the
  /// zoom-dependent stream visibility + "zoom in" hint.
  void _onMapIdle(MapIdleEventData data) {
    _controlsService.saveLastCameraPosition();
    _reconcileZoomState();
  }

  /// Hide streams (and surface the hint) when zoomed out past the usable range;
  /// restore them when zoomed back in. Driven off map-idle so it tracks pans
  /// and zooms without a continuous camera listener.
  Future<void> _reconcileZoomState() async {
    final zoom = await _vectorTilesService.getCurrentZoom();
    if (zoom == null || !mounted) return;

    await _vectorTilesService.updateVisibilityForZoom(zoom);

    final tooFarOut = zoom < AppConfig.minZoomForVectorTiles;
    if (tooFarOut != _showZoomHint) {
      setState(() => _showZoomHint = tooFarOut);
    }
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
    // Streams aren't rendered or reliably tappable below the usable zoom, so
    // don't run a query that would silently miss — the hint tells the user to
    // zoom in.
    final zoom = await _vectorTilesService.getCurrentZoom();
    if (zoom != null && zoom < AppConfig.minZoomForVectorTiles) {
      if (mounted && !_showZoomHint) setState(() => _showZoomHint = true);
      return;
    }

    // Handle normal reach selection
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
