// lib/features/map/map_page.dart

import 'package:flutter/cupertino.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:rivr/core/widgets/navigation_button.dart';
import 'package:rivr/core/services/app_logger.dart';
import 'package:rivr/core/routing/app_router.dart';
import 'package:rivr/features/map/widgets/map_search_widget.dart';
// NEW IMPORTS
import 'package:rivr/features/map/widgets/map_control_buttons.dart';
import 'package:rivr/features/map/widgets/base_layer_modal.dart';
import 'package:rivr/features/map/widgets/streams_list_bottom_sheet.dart'; // NEW: Import streams list
import 'package:rivr/features/map/services/map_controls_service.dart';
// EXISTING IMPORTS
import 'package:get_it/get_it.dart';
import 'package:rivr/core/services/i_cache_service.dart';
import '../../core/config.dart';
import '../../core/constants.dart';
import '../../core/providers/theme_provider.dart';
import 'services/map_vector_tiles_service.dart';
import 'services/map_reach_selection_service.dart';
import 'services/map_marker_service.dart';
import 'services/map_service_factory.dart';
import 'models/selected_reach.dart';
// UPDATED: Import the optimized bottom sheet
import 'widgets/reach_details_bottom_sheet.dart';

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
  ThemeProvider? _themeProvider;
  Brightness? _lastBrightness;

  // Restored camera position (loaded before first build)
  ({double lat, double lng, double zoom})? _savedCamera;

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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final themeProvider = Provider.of<ThemeProvider>(context);
    _themeProvider = themeProvider;

    // Compare brightness values instead of provider references, since
    // Provider always returns the same ChangeNotifier instance.
    final newBrightness = themeProvider.currentBrightness;
    if (_lastBrightness != null &&
        _lastBrightness != newBrightness &&
        _mapboxMap != null) {
      _updateMapForThemeChange();
    }
    _lastBrightness = newBrightness;
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

  /// Update map when theme changes
  Future<void> _updateMapForThemeChange() async {
    if (_themeProvider != null) {
      await _controlsService.updateMapForThemeChange(_themeProvider!);
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
                onStreamsPressed: _showStreamsModal,
                onRecenterPressed: _recenterToLocation,
                on3DTogglePressed: _toggle3DTerrain,
                is3DEnabled: _controlsService.is3DEnabled,
                is3DAvailable: _controlsService.supports3D,
              ),
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

  /// Save camera position when the map stops moving
  void _onMapIdle(MapIdleEventData data) {
    _controlsService.saveLastCameraPosition();
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

      // Initialize map style based on preferences and theme
      if (_themeProvider != null) {
        await _controlsService.initializeMapStyle(_themeProvider!);
      }

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
      if (_themeProvider != null) {
        await _controlsService.applyLightPreset(_themeProvider!);
      }

      // Reset vector tiles state (safe for both initial and subsequent loads)
      _vectorTilesService.dispose();
      _vectorTilesService.setMapboxMap(_mapboxMap!);

      // Load vector tiles
      await _vectorTilesService.loadRiverReaches();

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
    // Handle normal reach selection
    await _reachSelectionService.handleMapTap(context);
  }

  // UPDATED: Call bottom sheet directly without helper function
  void _onReachSelected(SelectedReach selectedReach) {
    showCupertinoModalPopup(
      context: context,
      builder: (context) => ReachDetailsBottomSheet(
        selectedReach: selectedReach,
        onViewForecast: () => _navigateToForecast(selectedReach),
      ),
    );
  }

  void _onEmptyTap(Point point) {
    // Could add feedback here if needed
    // For now, just let any open bottom sheet stay open
  }

  void _navigateToForecast(SelectedReach selectedReach) {
    Navigator.of(context).pop(); // Close bottom sheet

    // Navigate to forecast page with reachId
    AppRouter.pushForecast(context, reachId: selectedReach.reachId);
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
