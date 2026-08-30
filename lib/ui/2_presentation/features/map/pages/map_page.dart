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
import 'package:rivr/models/1_domain/features/map/selected_reach.dart';
// UPDATED: Import the optimized bottom sheet
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_details_bottom_sheet.dart';
import 'package:rivr/services/4_infrastructure/map/flood_tileset_service.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/condition_legend.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/map_offline_notice.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rivr/models/1_domain/shared/location_denial.dart';

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

  /// Whether the camera has already been moved to the user, this app run.
  ///
  /// **Static on purpose.** `_MapPageState` is recreated every time the map
  /// tab is opened, so an instance field would be false again on the second
  /// open and the camera would jump — exactly the behaviour being removed.
  /// Static makes "first open" mean first open of the app run, which is what
  /// a person means by it.
  ///
  /// Not persisted across launches: a fresh launch centring on you once is
  /// helpful, and the alternative is a stored flag that makes the app behave
  /// differently on day two for reasons the user cannot see.
  static bool _hasCenteredOnUser = false;

  /// Where the camera was when the map was last closed, this app run.
  ///
  /// **Static, for the same reason [_hasCenteredOnUser] is.** The map page is
  /// pushed fresh by `Navigator.pushNamed` every time, so an instance field
  /// would be gone before it could be read.
  ///
  /// Stored as plain numbers rather than a `CameraOptions`, so nothing holds
  /// a reference to a disposed platform object.
  ///
  /// **Not persisted across launches, deliberately.** Restoring a camera from
  /// a week ago drops someone onto a river they looked at once; restoring one
  /// from ten minutes ago returns them to what they were doing. The first is
  /// the reason the camera was un-persisted on 2026-08-20, and the second is
  /// why session memory is worth having.
  static ({double lat, double lon, double zoom})? _rememberedCamera;
  bool _isLoading = true;
  String? _errorMessage;
  MapboxMap? _mapboxMap;


  // Which stream networks are drawn (persisted; Auto default until loaded).
  StreamLayerVisibility _streamLayers = StreamLayerVisibility.defaults;

  // The date the flood colours describe. Empty until Remote Config lands —
  // which happens *after* first build, so it must live in state or the legend
  // renders once with no date and never updates.
  String _floodDataDate = '';

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
    _loadStreamLayerPrefs();
  }

  /// Load the persisted stream-network toggles for the modal's initial state.
  /// The authoritative apply-to-map happens in [_loadLayersAfterStyleReady].
  Future<void> _loadStreamLayerPrefs() async {
    final layers = await MapPreferenceService.loadStreamLayers();
    if (mounted) {
      setState(() => _streamLayers = layers);
    }
  }

  @override
  void dispose() {
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

        // Why the map has stopped filling in. Centred in the band between the
        // back button and the control stack — the one strip of chrome-free
        // space up top — and width-capped so it cannot grow into either.
        Positioned(
          top: 30,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: const MapOfflineNotice(),
                ),
              ),
            ),
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

        // Flood-risk key. Always visible: the flood layer is always on, and
        // the colours mean nothing without it.
        Positioned(
          left: 16,
          bottom: 96,
          child: SafeArea(
            child: ConditionLegend(
              dataDate: _floodDataDate,
            ),
          ),
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
    // The map always opens somewhere predictable rather than wherever it was
    // last left. Reopening onto an arbitrary previous view is disorienting —
    // the user has usually come back to look at *here*, not to resume a pan
    // from days ago.
    //
    // This is the fallback, used when location is unavailable or refused.
    // Once the map exists, [_onMapCreated] recentres on the device location if
    // one can be obtained; that has to happen imperatively because
    // cameraOptions is only read at widget creation, long before a location
    // fix arrives.
    return MapWidget(
      // Where the user left it, or the configured default on a first open.
      //
      // On the FIRST open the remembered camera is null and the location
      // handler flies to the user a moment later; on every open after that
      // this is the whole behaviour, because that handler no longer recentres.
      cameraOptions: CameraOptions(
        center: Point(
          coordinates: Position(
            _rememberedCamera?.lon ?? AppConfig.defaultLongitude,
            _rememberedCamera?.lat ?? AppConfig.defaultLatitude,
          ),
        ),
        zoom: _rememberedCamera?.zoom ?? AppConfig.defaultZoom,
      ),
      styleUri: AppConstants.defaultMapboxStyleUrl,
      textureView: true,
      onMapCreated: _onMapCreated,
      onTapListener: _onMapTap,
      onStyleLoadedListener: _onStyleLoaded,
      onMapIdleListener: _onMapIdle,
    );
  }

  /// Remember where the user left the camera, so reopening the map returns
  /// them to it rather than to Provo.
  ///
  /// Idle is the right moment: it fires once the gesture has settled, so this
  /// records a resting position rather than every frame of a pan.
  ///
  /// **This used to do nothing**, back when the map recentred on the user on
  /// EVERY open — there was genuinely nothing to restore. Making that
  /// first-open-only (Jerson, 2026-08-30) removed the thing that made
  /// discarding the camera safe: reopening then landed on the configured
  /// default, which is useful for exactly one person, the one in Provo.
  void _onMapIdle(MapIdleEventData data) {
    final map = _mapboxMap;
    if (map == null) return;
    map.getCameraState().then((camera) {
      _rememberedCamera = (
        lat: camera.center.coordinates.lat.toDouble(),
        lon: camera.center.coordinates.lng.toDouble(),
        zoom: camera.zoom,
      );
    }).catchError((Object e) {
      // A camera we cannot read is simply not remembered; the next open falls
      // back to the default, which is where it went before this existed.
      AppLogger.debug('MapPage', 'Could not read camera state: $e');
    });
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

      // Start location initialization (does not depend on style being loaded).
      //
      // **Centre on the FIRST open only.** This used to recentre on every
      // open, which was reasonable while the map showed no location marker at
      // all — the jump was the only way to know where you were. Now that the
      // puck draws the user's position, recentring on every open just takes
      // them away from wherever they had panned to, and the puck tells them
      // where they are without moving the camera. Jerson's call, 2026-08-30.
      //
      // After the first open, the recentre button is the way back.
      //
      // The location is still REQUESTED every time: the puck needs a fix to
      // draw, and `initializeLocation` is what prompts for permission. Only
      // the camera move is first-open-only.
      _controlsService.initializeLocation().then((position) {
        if (position != null && mounted) {
          if (!_hasCenteredOnUser) {
            _hasCenteredOnUser = true;
            _controlsService.recenterToDeviceLocation();
            AppLogger.info('MapPage', 'Centered on device location (first open)');
          } else {
            AppLogger.info(
              'MapPage',
              'Location available; camera left where the user put it',
            );
          }
        } else {
          AppLogger.info(
            'MapPage',
            'No location available — staying on default view',
          );
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

      // The blue dot, and the accuracy ring around it.
      //
      // Re-applied on EVERY style load, not just the first: changing the
      // basemap rebuilds the style and takes the location component with it,
      // so a puck enabled once would silently vanish the first time someone
      // switched to satellite.
      await _controlsService.enableLocationPuck();

      // Reset vector tiles state (safe for both initial and subsequent loads).
      // Same race as the marker init below — bail rather than force-unwrap.
      // onStyleLoaded can fire before onMapCreated has handed us the map.
      // Wait briefly for it rather than force-unwrapping (which threw
      // "Null check operator used on a null value", surfaced as a full-screen
      // "Failed to load river data") or returning outright (which strands the
      // loading spinner forever).
      var mapForTiles = _mapboxMap;
      for (var i = 0; mapForTiles == null && i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (!mounted) return;
        mapForTiles = _mapboxMap;
      }
      if (mapForTiles == null) {
        AppLogger.warning('MapPage', 'Map handle never arrived — aborting load');
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      _vectorTilesService.dispose();
      _vectorTilesService.setMapboxMap(mapForTiles);

      // Load vector tiles
      await _vectorTilesService.loadRiverReaches();

      // The flood source is built from whatever tileset id the service knew at
      // style-load time. On a cold start Remote Config is usually still in
      // flight then, so the source may have been created from the date-derived
      // fallback. Re-check once it has landed and swap the source if the
      // published id differs — a no-op in the common case.
      unawaited(
        GetIt.I<FloodTilesetService>().initialize().then((_) async {
          await _vectorTilesService.refreshFloodTileset();
          final date = GetIt.I<FloodTilesetService>().dataDate;
          if (mounted && date != _floodDataDate) {
            setState(() => _floodDataDate = date);
          }
        }),
      );

      // Restore the saved stream-network toggles onto the freshly loaded layers.
      final streamLayers = await MapPreferenceService.loadStreamLayers();
      if (mounted) setState(() => _streamLayers = streamLayers);
      await _vectorTilesService.applyStreamVisibility(
        nwm: streamLayers.nwm,
        geoglowsWorld: streamLayers.geoglowsWorld,
        geoglowsUs: streamLayers.geoglowsUs,
      );

      // Initialize markers on top of vector tiles (correct z-ordering).
      //
      // Guarded rather than force-unwrapped: onStyleLoaded can fire before
      // _mapboxMap is assigned (and after dispose), and a `!` here threw
      // "Null check operator used on a null value" — surfaced to the user as
      // "Failed to load river data", a full-screen Map Error with a Retry
      // button, on a perfectly healthy map. It presents as random because it is
      // a startup race; regions whose tiles resolve quickly hit it repeatedly.
      final map = _mapboxMap;
      if (map != null) {
        await _markerService.initializeMarkers(map);
      } else {
        AppLogger.warning(
          'MapPage',
          'Style ready before map handle was set — skipping marker init',
        );
      }

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

  /// Recentre on the device, and SAY SOMETHING when that is not possible.
  ///
  /// This used to be a silent dead end: with location refused, the tap
  /// produced no message, no prompt and no route to Settings — the service
  /// logged an error and returned. The streams button beside it has shown a
  /// dialog for its own empty case since long before. Found by Jerson asking
  /// what happens when location is not granted, not by a test.
  void _recenterToLocation() async {
    // The RETURN value, not a field read afterwards. Reading a field meant
    // the answer depended on statement order inside the service, and two
    // orderings were wrong: a cached position could move the camera AND
    // raise "Can't Find Your Location", and a not-ready map could show a
    // permissions dialog left over from a previous attempt.
    final denial = await _controlsService.recenterToDeviceLocation();
    if (!mounted || denial == null) return;

    _showLocationDenialDialog(denial);
  }

  /// Explain why the map could not centre, and offer Settings when Settings
  /// is actually the fix.
  void _showLocationDenialDialog(LocationDenial denial) {
    final message = locationDenialMessage(denial);

    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(message.title),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(message.body),
        ),
        actions: [
          if (message.openSettings)
            CupertinoDialogAction(
              onPressed: () {
                Navigator.pop(context);
                openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(context),
            child: Text(message.openSettings ? 'Not Now' : 'OK'),
          ),
        ],
      ),
    );
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
