// lib/services/4_infrastructure/map/map_preference_service.dart

import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/models/1_domain/shared/map_base_layer.dart';

/// Map preference options
enum MapPreferenceOption {
  auto, // Use default map style (standard/light)
  manual, // User manually selected a specific map style
}

/// Which stream networks are drawn on the map. Auto default = NWM (US) +
/// GEOGLOWS outside the US; GEOGLOWS inside the US is off (it overlaps NWM and
/// is meant for Compare/Global use).
class StreamLayerVisibility {
  final bool nwm;
  final bool geoglowsWorld; // GEOGLOWS outside the US
  final bool geoglowsUs; // GEOGLOWS inside the US

  const StreamLayerVisibility({
    required this.nwm,
    required this.geoglowsWorld,
    required this.geoglowsUs,
  });

  static const StreamLayerVisibility defaults = StreamLayerVisibility(
    nwm: true,
    geoglowsWorld: true,
    geoglowsUs: false,
  );

  StreamLayerVisibility copyWith({
    bool? nwm,
    bool? geoglowsWorld,
    bool? geoglowsUs,
  }) => StreamLayerVisibility(
    nwm: nwm ?? this.nwm,
    geoglowsWorld: geoglowsWorld ?? this.geoglowsWorld,
    geoglowsUs: geoglowsUs ?? this.geoglowsUs,
  );
}

/// Service for managing map base layer preferences
/// Manages map base layer preferences
class MapPreferenceService {
  static const String _mapPreferenceKey = 'map_preference_option';
  static const String _mapBaseLayerKey = 'map_base_layer';
  static const String _nwmVisibleKey = 'stream_layer_nwm';
  static const String _geoglowsWorldVisibleKey = 'stream_layer_geoglows_world';
  static const String _geoglowsUsVisibleKey = 'stream_layer_geoglows_us';

  /// Load map preference from storage
  static Future<MapPreferenceOption> loadMapPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final preferenceString = prefs.getString(_mapPreferenceKey);

    switch (preferenceString) {
      case 'auto':
        return MapPreferenceOption.auto;
      case 'manual':
        return MapPreferenceOption.manual;
      default:
        return MapPreferenceOption.auto; // Default to auto mode
    }
  }

  /// Save map preference to storage
  static Future<void> saveMapPreference(MapPreferenceOption preference) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mapPreferenceKey, preference.name);
  }

  /// Load manually selected map base layer from storage
  static Future<MapBaseLayer> loadManualMapLayer() async {
    final prefs = await SharedPreferences.getInstance();
    final layerString = prefs.getString(_mapBaseLayerKey);

    // Convert string back to enum
    for (final layer in MapBaseLayer.values) {
      if (layer.name == layerString) {
        return layer;
      }
    }

    return MapBaseLayer.standard;
  }

  /// Save manually selected map base layer to storage
  static Future<void> saveManualMapLayer(MapBaseLayer layer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mapBaseLayerKey, layer.name);
  }

  /// Get the appropriate map layer based on current preference
  /// This is the main method that determines what map style to use
  static Future<MapBaseLayer> getActiveMapLayer() async {
    final preference = await loadMapPreference();

    switch (preference) {
      case MapPreferenceOption.auto:
        return MapBaseLayer.standard;

      case MapPreferenceOption.manual:
        return await loadManualMapLayer();
    }
  }

  /// Set manual map layer preference (switches to manual mode)
  static Future<void> setManualMapLayer(MapBaseLayer layer) async {
    // Save the layer choice
    await saveManualMapLayer(layer);

    // Switch to manual mode
    await saveMapPreference(MapPreferenceOption.manual);
  }

  /// Switch back to auto mode (follow theme)
  static Future<void> enableAutoMode() async {
    await saveMapPreference(MapPreferenceOption.auto);
  }

  /// Check if currently in auto mode
  static Future<bool> isAutoMode() async {
    final preference = await loadMapPreference();
    return preference == MapPreferenceOption.auto;
  }

  /// Load which stream networks should be drawn (defaults if never set).
  static Future<StreamLayerVisibility> loadStreamLayers() async {
    final prefs = await SharedPreferences.getInstance();
    return StreamLayerVisibility(
      nwm: prefs.getBool(_nwmVisibleKey) ?? StreamLayerVisibility.defaults.nwm,
      geoglowsWorld:
          prefs.getBool(_geoglowsWorldVisibleKey) ??
          StreamLayerVisibility.defaults.geoglowsWorld,
      geoglowsUs:
          prefs.getBool(_geoglowsUsVisibleKey) ??
          StreamLayerVisibility.defaults.geoglowsUs,
    );
  }

  /// Persist which stream networks should be drawn.
  static Future<void> saveStreamLayers(StreamLayerVisibility layers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_nwmVisibleKey, layers.nwm);
    await prefs.setBool(_geoglowsWorldVisibleKey, layers.geoglowsWorld);
    await prefs.setBool(_geoglowsUsVisibleKey, layers.geoglowsUs);
  }

  /// Reset all map preferences to defaults
  static Future<void> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_mapPreferenceKey);
    await prefs.remove(_mapBaseLayerKey);
    await prefs.remove(_nwmVisibleKey);
    await prefs.remove(_geoglowsWorldVisibleKey);
    await prefs.remove(_geoglowsUsVisibleKey);
  }
}
