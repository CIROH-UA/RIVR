// lib/features/map/services/map_controls_service.dart

import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/map_preference_service.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/providers/theme_provider.dart';
import 'package:rivr/core/models/map_base_layer.dart';

class MapControlsService {
  MapboxMap? _mapboxMap;
  MapBaseLayer _currentLayer = MapBaseLayer.standard;
  geo.Position? _lastKnownLocation;
  bool _is3DEnabled = false;
  bool _isToggling3D = false;
  String _currentLightPreset = 'day';

  // Default camera settings (you can adjust these based on your app's needs)
  static const double _defaultZoom = 14.0;
  static const int _animationDurationMs = 1000;
  static const String _terrain3DKey = 'terrain_3d_enabled';
  static const String _cameraLatKey = 'map_camera_lat';
  static const String _cameraLngKey = 'map_camera_lng';
  static const String _cameraZoomKey = 'map_camera_zoom';

  MapBaseLayer get currentLayer => _currentLayer;
  geo.Position? get lastKnownLocation => _lastKnownLocation;
  bool get is3DEnabled => _is3DEnabled;
  bool get supports3D => _currentLayer.supports3D;

  /// Whether the current map appearance has a dark background.
  /// Standard basemap always uses light preset, so only satellite layers are dark.
  bool get isMapDark {
    return _currentLayer.hasDarkBackground;
  }

  void setMapboxMap(MapboxMap mapboxMap) {
    _mapboxMap = mapboxMap;
  }

  /// Apply lightPreset on Standard style.
  /// Always forces 'day' so the Standard basemap stays light regardless of app theme.
  Future<void> applyLightPreset(ThemeProvider themeProvider) async {
    if (_currentLayer != MapBaseLayer.standard || _mapboxMap == null) return;
    if (_currentLightPreset != 'day') {
      await _mapboxMap!.style.setStyleImportConfigProperty("basemap", "lightPreset", "day");
      _currentLightPreset = 'day';
      AppLogger.info('MapControlsService', 'Light preset set to: day');
    }
  }

  /// Initialize map with correct style based on theme and preferences
  Future<void> initializeMapStyle(ThemeProvider themeProvider) async {
    if (_mapboxMap == null) {
      AppLogger.error('MapControlsService', 'Map not initialized');
      return;
    }

    try {
      // Get the active map layer based on preferences and theme
      final activeLayer = await MapPreferenceService.getActiveMapLayer(
        themeProvider,
      );

      // Load 3D terrain preference
      await _load3DTerrainPreference();

      // Apply the style if it's different from current
      if (activeLayer != _currentLayer) {
        await _mapboxMap!.loadStyleURI(activeLayer.styleUrl);
        _currentLayer = activeLayer;
        AppLogger.info('MapControlsService', 'Map initialized with layer: ${activeLayer.displayName}');
      }

      // 3D terrain is applied via onStyleLoaded → _loadLayersAfterStyleReady
      // → applyTerrainIfEnabled(), not here, to ensure the style is fully ready.
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error initializing map style', e);
    }
  }

  /// Update map appearance when theme changes.
  /// Standard basemap always stays light, so this is a no-op for it.
  /// Non-Standard basemaps don't change with theme either.
  Future<void> updateMapForThemeChange(ThemeProvider themeProvider) async {
    // No basemap changes on theme switch — Standard is always light,
    // and other basemaps have fixed styles.
  }

  /// Change map base layer (manual selection by user)
  Future<void> changeBaseLayer(MapBaseLayer newLayer) async {
    if (_mapboxMap == null) {
      AppLogger.error('MapControlsService', 'Map not initialized');
      return;
    }

    try {
      // Disable 3D if the new layer doesn't support it
      if (_is3DEnabled && !newLayer.supports3D) {
        _is3DEnabled = false;
        await _save3DTerrainPreference(false);
      }

      // Update the map style
      await _mapboxMap!.loadStyleURI(newLayer.styleUrl);
      _currentLayer = newLayer;
      _currentLightPreset = 'day'; // Reset; actual preset applied in _loadLayersAfterStyleReady
      // 3D terrain will be re-applied via onStyleLoaded → applyTerrainIfEnabled()

      // Save as manual preference (switches to manual mode)
      await MapPreferenceService.setManualMapLayer(newLayer);

      AppLogger.info('MapControlsService', 'Map layer manually changed to: ${newLayer.displayName}');
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error changing map layer', e);
    }
  }

  /// Toggle 3D terrain on/off (public method for UI button).
  /// Adds/removes terrain directly — no style reload needed.
  /// Guard prevents concurrent toggles from creating race conditions.
  Future<void> toggle3DTerrain() async {
    if (_isToggling3D) return;
    _isToggling3D = true;
    try {
      if (_is3DEnabled) {
        await _disable3DTerrain();
        await _save3DTerrainPreference(false);
      } else {
        _is3DEnabled = true;
        await _save3DTerrainPreference(true);
        await _enable3DTerrain();
      }
    } finally {
      _isToggling3D = false;
    }
  }

  /// Apply 3D terrain if enabled. Called from MapPage._onStyleLoaded
  /// after every style reload to ensure terrain + 3D buildings are active.
  Future<void> applyTerrainIfEnabled() async {
    if (_is3DEnabled) {
      await _enable3DTerrain();
    }
  }

  /// Load 3D terrain preference from storage
  Future<void> _load3DTerrainPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _is3DEnabled = prefs.getBool(_terrain3DKey) ?? false;
      AppLogger.debug('MapControlsService', 'Loaded 3D terrain preference: $_is3DEnabled');
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error loading 3D terrain preference', e);
      _is3DEnabled = false;
    }
  }

  /// Save 3D terrain preference to storage
  Future<void> _save3DTerrainPreference(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_terrain3DKey, enabled);
      AppLogger.debug('MapControlsService', 'Saved 3D terrain preference: $enabled');
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error saving 3D terrain preference', e);
    }
  }

  /// Enable 3D terrain
  Future<void> _enable3DTerrain() async {
    if (_mapboxMap == null) return;

    try {
      // Add terrain source (may already exist after a style reload)
      try {
        final terrainSource = RasterDemSource(
          id: 'mapbox-dem',
          url: "mapbox://mapbox.mapbox-terrain-dem-v1",
          tileSize: 512,
          maxzoom: 14,
        );
        await _mapboxMap!.style.addSource(terrainSource);
      } catch (_) {
        // Source already exists — safe to continue
      }

      await _mapboxMap!.style.setStyleTerrainProperty("source", "mapbox-dem");
      await _mapboxMap!.style.setStyleTerrainProperty("exaggeration", 1.5);

      // Tilt camera for 3D effect (fire-and-forget so toggle releases quickly)
      final currentCamera = await _mapboxMap!.getCameraState();
      _mapboxMap!.flyTo(
        CameraOptions(
          center: currentCamera.center,
          zoom: currentCamera.zoom,
          pitch: 60.0,
          bearing: currentCamera.bearing,
        ),
        MapAnimationOptions(duration: 1500),
      );

      _is3DEnabled = true;
      AppLogger.info('MapControlsService', '3D terrain enabled');
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error enabling 3D terrain', e);
    }
  }

  /// Disable 3D terrain
  Future<void> _disable3DTerrain() async {
    if (_mapboxMap == null) return;

    try {
      // Clear terrain property first, then remove the source
      await _mapboxMap!.style.setStyleTerrainProperty("source", "");
      try {
        await _mapboxMap!.style.removeStyleSource('mapbox-dem');
      } catch (_) {
        // Source may not exist if terrain was never fully enabled
      }

      // Reset camera to flat view (fire-and-forget so toggle releases quickly)
      final currentCamera = await _mapboxMap!.getCameraState();
      _mapboxMap!.flyTo(
        CameraOptions(
          center: currentCamera.center,
          zoom: currentCamera.zoom,
          pitch: 0.0,
          bearing: currentCamera.bearing,
        ),
        MapAnimationOptions(duration: 1000),
      );

      _is3DEnabled = false;
      AppLogger.info('MapControlsService', '3D terrain disabled');
    } catch (e) {
      // Ensure state is reset even if something fails
      _is3DEnabled = false;
      AppLogger.error('MapControlsService', 'Error disabling 3D terrain', e);
    }
  }

  /// Reset to auto mode (follows app theme)
  Future<void> enableAutoMode(ThemeProvider themeProvider) async {
    try {
      // Enable auto mode in preferences
      await MapPreferenceService.enableAutoMode();

      // Auto mode always uses Standard — switch if needed
      final autoLayer = await MapPreferenceService.getActiveMapLayer(themeProvider);
      if (autoLayer != _currentLayer) {
        await _mapboxMap?.loadStyleURI(autoLayer.styleUrl);
        _currentLayer = autoLayer;
        _currentLightPreset = 'day'; // Reset; actual preset applied after style loads
      } else {
        // Already on Standard, just update lightPreset
        await applyLightPreset(themeProvider);
      }

      AppLogger.info('MapControlsService', 'Map set to auto mode');
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error enabling auto mode', e);
    }
  }

  /// Check if map is in auto mode
  Future<bool> isAutoMode() async {
    try {
      return await MapPreferenceService.isAutoMode();
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error checking auto mode', e);
      return true; // Default to auto mode
    }
  }

  /// Initialize location services and get current position
  Future<geo.Position?> initializeLocation() async {
    try {
      // Check if location services are enabled
      bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        AppLogger.error('MapControlsService', 'Location services are disabled');
        return null;
      }

      // Check permissions
      geo.LocationPermission permission =
          await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
        if (permission == geo.LocationPermission.denied) {
          AppLogger.error('MapControlsService', 'Location permissions are denied');
          return null;
        }
      }

      if (permission == geo.LocationPermission.deniedForever) {
        AppLogger.error('MapControlsService', 'Location permissions are permanently denied');
        return null;
      }

      // Get current position
      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      _lastKnownLocation = position;
      AppLogger.debug('MapControlsService', 'Current location: ${position.latitude}, ${position.longitude}');
      return position;
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error getting location', e);
      return null;
    }
  }

  /// Recenter map to device location
  Future<void> recenterToDeviceLocation() async {
    if (_mapboxMap == null) {
      AppLogger.error('MapControlsService', 'Map not initialized');
      return;
    }

    try {
      // Try to get fresh location, but fall back to last known
      geo.Position? position = await initializeLocation();
      position ??= _lastKnownLocation;

      if (position == null) {
        AppLogger.error('MapControlsService', 'No location available for recentering');
        return;
      }

      // Create camera options for the new position
      final cameraOptions = CameraOptions(
        center: Point(
          coordinates: Position(position.longitude, position.latitude),
        ),
        zoom: _defaultZoom,
        pitch: _is3DEnabled ? 60.0 : 0.0,
      );

      // Animate to the new position
      await _mapboxMap!.flyTo(
        cameraOptions,
        MapAnimationOptions(duration: _animationDurationMs, startDelay: 0),
      );

      AppLogger.info('MapControlsService', 'Map recentered to device location');
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error recentering map', e);
    }
  }

  /// Get current map center for debugging/logging
  Future<Point?> getCurrentMapCenter() async {
    if (_mapboxMap == null) return null;

    try {
      final cameraState = await _mapboxMap!.getCameraState();
      return cameraState.center;
    } catch (e) {
      AppLogger.error('MapControlsService', 'Error getting map center', e);
      return null;
    }
  }

  /// Save the current camera position to SharedPreferences.
  /// Called from MapPage when the map stops moving.
  Future<void> saveLastCameraPosition() async {
    if (_mapboxMap == null) return;

    try {
      final camera = await _mapboxMap!.getCameraState();
      final center = camera.center;
      final lat = center.coordinates.lat.toDouble();
      final lng = center.coordinates.lng.toDouble();
      final zoom = camera.zoom;

      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setDouble(_cameraLatKey, lat),
        prefs.setDouble(_cameraLngKey, lng),
        prefs.setDouble(_cameraZoomKey, zoom),
      ]);

      AppLogger.debug('MapControlsService', 'Saved camera: $lat, $lng @ zoom $zoom');
    } catch (e) {
      AppLogger.warning('MapControlsService', 'Failed to save camera position: $e');
    }
  }

  /// Load the last saved camera position, or null if none exists.
  static Future<({double lat, double lng, double zoom})?> loadLastCameraPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble(_cameraLatKey);
      final lng = prefs.getDouble(_cameraLngKey);
      final zoom = prefs.getDouble(_cameraZoomKey);

      if (lat != null && lng != null && zoom != null) {
        AppLogger.debug('MapControlsService', 'Loaded camera: $lat, $lng @ zoom $zoom');
        return (lat: lat, lng: lng, zoom: zoom);
      }
    } catch (e) {
      AppLogger.warning('MapControlsService', 'Failed to load camera position: $e');
    }
    return null;
  }

  /// Clean up resources
  void dispose() {
    _mapboxMap = null;
    _lastKnownLocation = null;
  }
}
