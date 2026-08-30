// lib/services/4_infrastructure/map/map_controls_service.dart

import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/services/4_infrastructure/map/map_preference_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/models/1_domain/shared/map_base_layer.dart';
import 'package:rivr/models/1_domain/shared/location_denial.dart';

class MapControlsService {
  MapboxMap? _mapboxMap;
  MapBaseLayer _currentLayer = MapBaseLayer.standard;
  geo.Position? _lastKnownLocation;
  bool _is3DEnabled = false;
  bool _isToggling3D = false;
  String _currentLightPreset = 'day';

  // Zoom used when the camera moves to the device's location.
  //
  // **Twelve, not fourteen, and the tileset is why.**
  // `byu-hydroinformatics.nwm-channels-v3` is tiled z0-12 (confirmed from its
  // Mapbox metadata). Above 12 there is no more stream data — Mapbox stretches
  // the z12 tile, so the lines get thicker and no new stream ever appears.
  //
  // What the user lost for that: at zoom 14 a Pro Max shows about 1.6 km of
  // ground, at 12 about 6.4 km. So 14 threw away three quarters of the visible
  // area and bought nothing, and on a screen that narrow a small stream often
  // simply is not in frame. Reported by Jerson 2026-08-30: "streams are not
  // visible at that level usually."
  //
  // 12 is the sharpest zoom the data actually supports.
  static const double _defaultZoom = 12.0;
  static const int _animationDurationMs = 1000;

  /// Why the last location attempt produced nothing, or null if it succeeded.
  ///
  /// `initializeLocation` returns `Position?`, which collapses four different
  /// situations into one null — services off, refused, refused permanently,
  /// and simply no fix. The caller needs to tell them apart to say anything
  /// useful, and to know whether Settings would even help. Without this the
  /// recentre button was a silent dead end.
  LocationDenial? _lastDenial;

  /// See [_lastDenial]. Null when the last attempt succeeded.
  LocationDenial? get lastDenial => _lastDenial;
  static const String _terrain3DKey = 'terrain_3d_enabled';
  // The map camera is deliberately not persisted. It opens on the user's
  // location when one is available and on the configured default otherwise,
  // so there is nothing to restore. Keys retired 2026-08-20; values left in
  // SharedPreferences by older builds are simply ignored.

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
  /// Always forces 'day' so the Standard basemap stays light.
  Future<void> applyLightPreset() async {
    if (_currentLayer != MapBaseLayer.standard || _mapboxMap == null) return;
    if (_currentLightPreset != 'day') {
      await _mapboxMap!.style.setStyleImportConfigProperty("basemap", "lightPreset", "day");
      _currentLightPreset = 'day';
      AppLogger.info('MapControlsService', 'Light preset set to: day');
    }
  }

  /// Initialize map with correct style based on preferences
  Future<void> initializeMapStyle() async {
    if (_mapboxMap == null) {
      AppLogger.error('MapControlsService', 'Map not initialized');
      return;
    }

    try {
      // Get the active map layer based on preferences
      final activeLayer = await MapPreferenceService.getActiveMapLayer();

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

  /// Reset to auto mode (uses standard/light map style)
  Future<void> enableAutoMode() async {
    try {
      // Enable auto mode in preferences
      await MapPreferenceService.enableAutoMode();

      // Auto mode always uses Standard — switch if needed
      final autoLayer = await MapPreferenceService.getActiveMapLayer();
      if (autoLayer != _currentLayer) {
        await _mapboxMap?.loadStyleURI(autoLayer.styleUrl);
        _currentLayer = autoLayer;
        _currentLightPreset = 'day'; // Reset; actual preset applied after style loads
      } else {
        // Already on Standard, just update lightPreset
        await applyLightPreset();
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
        _lastDenial = LocationDenial.serviceDisabled;
        return null;
      }

      // Check permissions
      geo.LocationPermission permission =
          await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
        if (permission == geo.LocationPermission.denied) {
          AppLogger.error('MapControlsService', 'Location permissions are denied');
          _lastDenial = LocationDenial.denied;
          return null;
        }
      }

      if (permission == geo.LocationPermission.deniedForever) {
        AppLogger.error('MapControlsService', 'Location permissions are permanently denied');
        _lastDenial = LocationDenial.deniedForever;
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
      _lastDenial = null;
      // Accuracy is logged because the puck's ring is drawn from it: when a
      // ring looks wrong on a device, this is the number that explains it.
      AppLogger.debug('MapControlsService',
          'Current location: ${position.latitude}, ${position.longitude} '
          '(accuracy ${position.accuracy.toStringAsFixed(0)} m)');
      return position;
    } catch (e) {
      // Permission is fine; the device simply could not produce a fix — most
      // often the 10-second limit elapsing indoors.
      AppLogger.error('MapControlsService', 'Error getting location', e);
      _lastDenial = LocationDenial.noFix;
      return null;
    }
  }

  /// Show the user's position on the map: a dot, with a ring when the fix is
  /// vague.
  ///
  /// **Mapbox's own location component, not a custom layer.** It draws the
  /// accuracy ring from the radius the device itself reports, in real metres,
  /// so the ring shrinks and grows correctly as the user zooms and needs no
  /// code of ours to keep it honest. A precise fix is a small dot; a poor one
  /// is visibly a circle, which is the whole point — the map stops implying a
  /// precision it does not have.
  ///
  /// Every one of these settings defaults to FALSE, which is why the map
  /// showed nothing at all before: it flew to the user's position and then
  /// gave no indication of where that was, leaving the centre of the screen as
  /// the only clue.
  ///
  /// Failure is logged and swallowed. A map without a blue dot is worth far
  /// more than no map, and this runs after the style loads where a throw would
  /// take the page down.
  Future<void> enableLocationPuck() async {
    if (_mapboxMap == null) {
      AppLogger.error('MapControlsService', 'Map not initialized');
      return;
    }
    try {
      await _mapboxMap!.location.updateSettings(
        LocationComponentSettings(
          enabled: true,
          // The ring is the feature. Without it a vague fix looks exactly
          // like a precise one.
          showAccuracyRing: true,
          // No pulsing: it draws the eye to the user's position, and the
          // subject of this map is the rivers around them.
          pulsingEnabled: false,
        ),
      );
      AppLogger.info('MapControlsService', 'Location puck enabled');
    } catch (e) {
      AppLogger.error('MapControlsService', 'Could not enable location puck', e);
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



  /// Clean up resources
  void dispose() {
    _mapboxMap = null;
    _lastKnownLocation = null;
  }
}
