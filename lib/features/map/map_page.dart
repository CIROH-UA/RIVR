// lib/features/map/map_page.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:rivrflow/core/widgets/navigation_button.dart';
import 'package:rivrflow/features/map/widgets/map_search_widget.dart';
// NEW IMPORTS
import 'package:rivrflow/features/map/widgets/map_control_buttons.dart';
import 'package:rivrflow/features/map/widgets/base_layer_modal.dart';
import 'package:rivrflow/features/map/widgets/streams_list_bottom_sheet.dart'; // NEW: Import streams list
import 'package:rivrflow/features/map/services/map_controls_service.dart';
// EXISTING IMPORTS
import '../../core/config.dart';
import '../../core/constants.dart';
import '../../core/providers/theme_provider.dart';
import '../../core/services/cache_service.dart';
import 'services/map_vector_tiles_service.dart';
import 'services/map_reach_selection_service.dart';
import 'services/map_marker_service.dart'; // Dedicated marker service
import 'models/selected_reach.dart';
// UPDATED: Import the optimized bottom sheet
import 'widgets/reach_details_bottom_sheet.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => MapPageState();
}

class MapPageState extends State<MapPage> {
  final _vectorTilesService = MapVectorTilesService();
  final _reachSelectionService = MapReachSelectionService();
  final _markerService = MapMarkerService(); // Marker service
  final _controlsService = MapControlsService(); // NEW: Controls service

  bool _isLoading = true;
  String? _errorMessage;
  MapboxMap? _mapboxMap;
  ThemeProvider? _themeProvider;

  @override
  void initState() {
    super.initState();
    _setupSelectionCallbacks();
    _initializeCacheService();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Set up theme listener
    final themeProvider = Provider.of<ThemeProvider>(context);

    // If theme provider changed, update map
    if (_themeProvider != themeProvider) {
      final oldTheme = _themeProvider?.currentBrightness;
      _themeProvider = themeProvider;

      // Update map if theme changed and map is ready
      if (oldTheme != null &&
          oldTheme != themeProvider.currentBrightness &&
          _mapboxMap != null) {
        _updateMapForThemeChange();
      }
    }
  }

  @override
  void dispose() {
    _vectorTilesService.dispose();
    _markerService.dispose();
    _controlsService.dispose(); // NEW: Clean up controls service
    super.dispose();
  }

  void _setupSelectionCallbacks() {
    _reachSelectionService.onReachSelected = _onReachSelected;
    _reachSelectionService.onEmptyTap = _onEmptyTap;
  }

  /// Initialize cache service for recent searches and other caching needs
  Future<void> _initializeCacheService() async {
    try {
      await CacheService().initialize();
      print('🗄️ Cache service initialized for recent searches');
    } catch (e) {
      print('❌ Cache service initialization error: $e');
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
            backgroundColor: CupertinoColors.white.withOpacity(0.95),
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
                // NEW: Add these two lines
                on3DTogglePressed: _toggle3DTerrain,
                is3DEnabled: _controlsService.is3DEnabled,
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
    return MapWidget(
      key: const ValueKey('map'),
      cameraOptions: CameraOptions(
        center: Point(
          coordinates: Position(
            AppConfig.defaultLongitude,
            AppConfig.defaultLatitude,
          ),
        ),
        zoom: AppConfig.defaultZoom,
      ),
      styleUri: AppConstants.defaultMapboxStyleUrl,
      textureView: true,
      onMapCreated: _onMapCreated,
      onTapListener: _onMapTap,
      onStyleLoadedListener: _onStyleLoaded, // NEW: Style loaded listener
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: CupertinoColors.systemBackground.withOpacity(0.8),
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
      print('🗺️ Map created, initializing...');

      // Wait a moment for map to fully initialize
      await Future.delayed(const Duration(milliseconds: 500));

      // Initialize core map services
      _vectorTilesService.setMapboxMap(mapboxMap);
      _reachSelectionService.setMapboxMap(mapboxMap);
      _controlsService.setMapboxMap(mapboxMap);

      // NEW: Initialize map style based on preferences and theme
      if (_themeProvider != null) {
        await _controlsService.initializeMapStyle(_themeProvider!);
      }

      print('🚀 Services initialized, loading initial content...');

      // Load vector tiles for initial style
      await _vectorTilesService.loadRiverReaches();

      // Initialize marker service
      await _markerService.initializeMarkers(mapboxMap);

      // NEW: Initialize location for controls
      await _controlsService.initializeLocation();

      print('✅ Map setup complete');

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      print('❌ Map creation error: $e');
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load river data: ${e.toString()}';
      });
    }
  }

  /// Called automatically when map style finishes loading
  /// This ensures vector tiles are always reloaded after base layer changes
  void _onStyleLoaded(StyleLoadedEventData data) {
    // Don't reload on the initial style load (already loaded in _onMapCreated)
    if (!_isLoading) {
      _reloadVectorTilesAfterStyleChange();
    }
  }

  /// Reload vector tiles after style change (async to avoid blocking style load)
  Future<void> _reloadVectorTilesAfterStyleChange() async {
    try {
      print('🎨 Style loaded, reloading vector tiles...');

      // Reset the vector tiles service state since the style changed
      _vectorTilesService.dispose();
      _vectorTilesService.setMapboxMap(_mapboxMap!);

      // Reload vector tiles on the new style
      await _vectorTilesService.loadRiverReaches();

      print('✅ Vector tiles automatically reloaded after style change');

      // NEW: Re-initialize marker service to ensure hearts stay on top
      await _reAddHeartMarkersOnTop();
    } catch (e) {
      print('❌ Error reloading vector tiles after style change: $e');
    }
  }

  /// Re-add heart markers to ensure they stay on top of vector tiles
  Future<void> _reAddHeartMarkersOnTop() async {
    try {
      // Re-initialize the marker service - this will automatically
      // re-add all current favorites that were stored in the service
      await _markerService.initializeMarkers(_mapboxMap!);

      print(
        '🔄 Heart markers re-initialized and will appear on top of vector tiles',
      );
    } catch (e) {
      print('❌ Error re-initializing heart markers: $e');
    }
  }

  void _showSearchModal() {
    if (_mapboxMap == null) {
      print('❌ Map not ready for search');
      return;
    }

    showMapSearchModal(
      context,
      mapboxMap: _mapboxMap,
      onPlaceSelected: (place) {
        print(
          '🎯 Selected place: ${place.shortName} at ${place.latitude}, ${place.longitude}',
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
        // Simply change the base layer - vector tiles will be automatically reloaded
        await _controlsService.changeBaseLayer(layer);
        print('🗺️ Layer changed to: ${layer.displayName}');
      },
    );
  }

  // NEW: Show streams modal
  void _showStreamsModal() async {
    if (_mapboxMap == null) {
      print('❌ Map not ready for streams list');
      return;
    }

    try {
      // Get visible streams from the reach selection service
      final visibleStreams = await _reachSelectionService.getVisibleStreams();

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
          print('🎯 Flying to stream: ${stream.stationId}');
        },
      );
    } catch (e) {
      print('❌ Error showing streams modal: $e');
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
    Navigator.of(
      context,
    ).pushNamed('/forecast', arguments: selectedReach.reachId);
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
