// lib/core/services/map_preference_service.dart

import 'package:shared_preferences/shared_preferences.dart';
import '../models/map_base_layer.dart';

/// Map preference options
enum MapPreferenceOption {
  auto, // Use default map style (standard/light)
  manual, // User manually selected a specific map style
}

/// Service for managing map base layer preferences
/// Manages map base layer preferences
class MapPreferenceService {
  static const String _mapPreferenceKey = 'map_preference_option';
  static const String _mapBaseLayerKey = 'map_base_layer';

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

  /// Reset all map preferences to defaults
  static Future<void> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_mapPreferenceKey);
    await prefs.remove(_mapBaseLayerKey);
  }
}
