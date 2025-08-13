// lib/features/map/services/map_controls_service.dart

import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/map_preference_service.dart';
import '../../../core/providers/theme_provider.dart';
import '../widgets/base_layer_modal.dart';

class MapControlsService {
  MapboxMap? _mapboxMap;
  MapBaseLayer _currentLayer = MapBaseLayer.standard;
  geo.Position? _lastKnownLocation;
  bool _is3DEnabled = false;

  // Default camera settings (you can adjust these based on your app's needs)
  static const double _defaultZoom = 14.0;
  static const int _animationDurationMs = 1000;
  static const String _terrain3DKey = 'terrain_3d_enabled';

  MapBaseLayer get currentLayer => _currentLayer;
  geo.Position? get lastKnownLocation => _lastKnownLocation;
  bool get is3DEnabled => _is3DEnabled;

  void setMapboxMap(MapboxMap mapboxMap) {
    _mapboxMap = mapboxMap;
  }

  /// Initialize map with correct style based on theme and preferences
  Future<void> initializeMapStyle(ThemeProvider themeProvider) async {
    if (_mapboxMap == null) {
      print('❌ Map not initialized');
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
        print('✅ Map initialized with layer: ${activeLayer.displayName}');
      }

      // Apply 3D terrain if enabled (independent of layer)
      if (_is3DEnabled) {
        await _enable3DTerrain();
      }
    } catch (e) {
      print('❌ Error initializing map style: $e');
    }
  }

  /// Update map style when theme changes (auto mode only)
  Future<void> updateMapForThemeChange(ThemeProvider themeProvider) async {
    if (_mapboxMap == null) {
      print('❌ Map not initialized');
      return;
    }

    try {
      // Only update if in auto mode
      final isAuto = await MapPreferenceService.isAutoMode();
      if (!isAuto) {
        print('📍 Map in manual mode, skipping auto theme update');
        return;
      }

      // Get the active layer for current theme
      final activeLayer = await MapPreferenceService.getActiveMapLayer(
        themeProvider,
      );

      // Apply the style if it's different from current
      if (activeLayer != _currentLayer) {
        await _mapboxMap!.loadStyleURI(activeLayer.styleUrl);
        _currentLayer = activeLayer;

        // Re-apply 3D terrain if it was enabled (after style change)
        if (_is3DEnabled) {
          await _enable3DTerrain();
        }

        print('✅ Map auto-updated for theme: ${activeLayer.displayName}');
      }
    } catch (e) {
      print('❌ Error updating map for theme: $e');
    }
  }

  /// Change map base layer (manual selection by user)
  Future<void> changeBaseLayer(MapBaseLayer newLayer) async {
    if (_mapboxMap == null) {
      print('❌ Map not initialized');
      return;
    }

    try {
      // Update the map style
      await _mapboxMap!.loadStyleURI(newLayer.styleUrl);
      _currentLayer = newLayer;

      // Re-apply 3D terrain if it was enabled (after style change)
      if (_is3DEnabled) {
        await _enable3DTerrain();
      }

      // Save as manual preference (switches to manual mode)
      await MapPreferenceService.setManualMapLayer(newLayer);

      print('✅ Map layer manually changed to: ${newLayer.displayName}');
    } catch (e) {
      print('❌ Error changing map layer: $e');
    }
  }

  /// Toggle 3D terrain on/off (public method for UI button)
  Future<void> toggle3DTerrain() async {
    if (_is3DEnabled) {
      await _disable3DTerrain();
    } else {
      await _enable3DTerrain();
    }

    // Save the preference
    await _save3DTerrainPreference(_is3DEnabled);
  }

  /// Load 3D terrain preference from storage
  Future<void> _load3DTerrainPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _is3DEnabled = prefs.getBool(_terrain3DKey) ?? false;
      print('📱 Loaded 3D terrain preference: $_is3DEnabled');
    } catch (e) {
      print('❌ Error loading 3D terrain preference: $e');
      _is3DEnabled = false;
    }
  }

  /// Save 3D terrain preference to storage
  Future<void> _save3DTerrainPreference(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_terrain3DKey, enabled);
      print('💾 Saved 3D terrain preference: $enabled');
    } catch (e) {
      print('❌ Error saving 3D terrain preference: $e');
    }
  }

  /// Enable 3D terrain
  Future<void> _enable3DTerrain() async {
    if (_mapboxMap == null) return;

    try {
      await Future.delayed(const Duration(milliseconds: 500));

      final terrainSource = RasterDemSource(
        id: 'mapbox-dem',
        url: "mapbox://mapbox.mapbox-terrain-dem-v1",
        tileSize: 512,
        maxzoom: 14,
      );

      await _mapboxMap!.style.addSource(terrainSource);
      await _mapboxMap!.style.setStyleTerrainProperty("source", "mapbox-dem");
      await _mapboxMap!.style.setStyleTerrainProperty("exaggeration", 1.5);

      // Tilt camera for 3D effect
      final currentCamera = await _mapboxMap!.getCameraState();
      await _mapboxMap!.flyTo(
        CameraOptions(
          center: currentCamera.center,
          zoom: currentCamera.zoom,
          pitch: 60.0,
          bearing: currentCamera.bearing,
        ),
        MapAnimationOptions(duration: 1500),
      );

      _is3DEnabled = true;
      print('✅ 3D terrain enabled');
    } catch (e) {
      print('❌ Error enabling 3D terrain: $e');
    }
  }

  /// Disable 3D terrain
  Future<void> _disable3DTerrain() async {
    if (_mapboxMap == null) return;

    try {
      await _mapboxMap!.style.removeStyleSource('mapbox-dem');

      // Reset camera to flat view
      final currentCamera = await _mapboxMap!.getCameraState();
      await _mapboxMap!.flyTo(
        CameraOptions(
          center: currentCamera.center,
          zoom: currentCamera.zoom,
          pitch: 0.0,
          bearing: currentCamera.bearing,
        ),
        MapAnimationOptions(duration: 1000),
      );

      _is3DEnabled = false;
      print('✅ 3D terrain disabled');
    } catch (e) {
      print('❌ Error disabling 3D terrain: $e');
    }
  }

  /// Reset to auto mode (follows app theme)
  Future<void> enableAutoMode(ThemeProvider themeProvider) async {
    try {
      // Enable auto mode in preferences
      await MapPreferenceService.enableAutoMode();

      // Update map to match current theme
      await updateMapForThemeChange(themeProvider);

      print('✅ Map set to auto mode');
    } catch (e) {
      print('❌ Error enabling auto mode: $e');
    }
  }

  /// Check if map is in auto mode
  Future<bool> isAutoMode() async {
    try {
      return await MapPreferenceService.isAutoMode();
    } catch (e) {
      print('❌ Error checking auto mode: $e');
      return true; // Default to auto mode
    }
  }

  /// Initialize location services and get current position
  Future<geo.Position?> initializeLocation() async {
    try {
      // Check if location services are enabled
      bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('❌ Location services are disabled');
        return null;
      }

      // Check permissions
      geo.LocationPermission permission =
          await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
        if (permission == geo.LocationPermission.denied) {
          print('❌ Location permissions are denied');
          return null;
        }
      }

      if (permission == geo.LocationPermission.deniedForever) {
        print('❌ Location permissions are permanently denied');
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
      print('📍 Current location: ${position.latitude}, ${position.longitude}');
      return position;
    } catch (e) {
      print('❌ Error getting location: $e');
      return null;
    }
  }

  /// Recenter map to device location
  Future<void> recenterToDeviceLocation() async {
    if (_mapboxMap == null) {
      print('❌ Map not initialized');
      return;
    }

    try {
      // Try to get fresh location, but fall back to last known
      geo.Position? position = await initializeLocation();
      position ??= _lastKnownLocation;

      if (position == null) {
        print('❌ No location available for recentering');
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

      print('✅ Map recentered to device location');
    } catch (e) {
      print('❌ Error recentering map: $e');
    }
  }

  /// Get current map center for debugging/logging
  Future<Point?> getCurrentMapCenter() async {
    if (_mapboxMap == null) return null;

    try {
      final cameraState = await _mapboxMap!.getCameraState();
      return cameraState.center;
    } catch (e) {
      print('❌ Error getting map center: $e');
      return null;
    }
  }

  /// Clean up resources
  void dispose() {
    _mapboxMap = null;
    _lastKnownLocation = null;
  }
}
