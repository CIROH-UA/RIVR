// lib/features/map/services/map_marker_service.dart (ENHANCED)

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import '../../../core/models/favorite_river.dart';
import '../../../core/services/app_logger.dart';

/// Dedicated service for managing map markers efficiently
/// Uses single annotation manager pattern with diff-based updates
/// Enhanced to handle style changes properly
class MapMarkerService {
  // Single annotation manager for all heart markers
  PointAnnotationManager? _annotationManager;
  MapboxMap? _mapboxMap;

  // Track current markers for efficient diff updates
  final Map<String, PointAnnotation> _heartMarkers = {};

  // Track which reach IDs currently have markers
  final Set<String> _currentMarkerReachIds = {};

  // NEW: Store current favorites to re-add after style changes
  List<FavoriteRiver> _currentFavorites = [];

  bool _isInitialized = false;

  /// Initialize the marker service with the map
  Future<void> initializeMarkers(MapboxMap mapboxMap) async {
    try {
      AppLogger.debug('MapMarkerService', 'Initializing marker service');

      _mapboxMap = mapboxMap;

      // Create single annotation manager for all heart markers
      _annotationManager = await _mapboxMap!.annotations
          .createPointAnnotationManager();

      _isInitialized = true;

      // NEW: Re-add any existing favorites if this is a re-initialization
      if (_currentFavorites.isNotEmpty) {
        AppLogger.debug(
          'MapMarkerService',
          'Re-adding ${_currentFavorites.length} favorites after style change',
        );
        await _reAddAllMarkers();
      }

      AppLogger.info('MapMarkerService', 'Marker service initialized');
    } catch (e) {
      AppLogger.error('MapMarkerService', 'Error initializing markers', e);
      _isInitialized = false;
    }
  }

  /// Update heart markers based on favorites list with diff-based approach
  Future<void> updateHeartMarkers(List<FavoriteRiver> favorites) async {
    if (!_isInitialized || _annotationManager == null) {
      AppLogger.warning(
        'MapMarkerService',
        'Service not initialized, skipping marker update',
      );
      return;
    }

    try {
      AppLogger.debug(
        'MapMarkerService',
        'Updating heart markers for ${favorites.length} favorites',
      );

      // NEW: Store current favorites for style change recovery
      _currentFavorites = List.from(favorites);

      // Get favorites that have coordinates and can be displayed
      final favoritesWithCoords = favorites
          .where((f) => f.hasCoordinates)
          .toList();
      final newReachIds = favoritesWithCoords.map((f) => f.reachId).toSet();

      // Diff calculation: find what to add and remove
      final toRemove = _currentMarkerReachIds.difference(newReachIds);
      final toAdd = newReachIds.difference(_currentMarkerReachIds);

      AppLogger.debug(
        'MapMarkerService',
        'Markers to add: ${toAdd.length}, to remove: ${toRemove.length}',
      );

      // Remove markers that are no longer favorites
      for (final reachId in toRemove) {
        await _removeMarker(reachId);
      }

      // Add markers for new favorites
      for (final reachId in toAdd) {
        final favorite = favoritesWithCoords.firstWhere(
          (f) => f.reachId == reachId,
        );
        await _addMarker(favorite);
      }

      AppLogger.info(
        'MapMarkerService',
        'Heart markers updated: ${_heartMarkers.length} total',
      );
    } catch (e) {
      AppLogger.error('MapMarkerService', 'Error updating heart markers', e);
    }
  }

  /// NEW: Re-add all current favorites (for style changes)
  Future<void> _reAddAllMarkers() async {
    try {
      // Clear existing marker tracking
      _heartMarkers.clear();
      _currentMarkerReachIds.clear();

      // Re-add all current favorites
      final favoritesWithCoords = _currentFavorites
          .where((f) => f.hasCoordinates)
          .toList();

      for (final favorite in favoritesWithCoords) {
        await _addMarker(favorite);
      }

      AppLogger.info(
        'MapMarkerService',
        'Re-added ${favoritesWithCoords.length} markers after style change',
      );
    } catch (e) {
      AppLogger.error('MapMarkerService', 'Error re-adding markers', e);
    }
  }

  /// Add a single heart marker for a favorite
  Future<void> addMarker(FavoriteRiver favorite) async {
    if (!_isInitialized || _annotationManager == null) {
      AppLogger.warning(
        'MapMarkerService',
        'Service not initialized, cannot add marker',
      );
      return;
    }

    if (!favorite.hasCoordinates) {
      AppLogger.warning(
        'MapMarkerService',
        'Cannot add marker for ${favorite.reachId} - no coordinates',
      );
      return;
    }

    await _addMarker(favorite);
  }

  /// Remove a single heart marker
  Future<void> removeMarker(String reachId) async {
    if (!_isInitialized || _annotationManager == null) {
      AppLogger.warning(
        'MapMarkerService',
        'Service not initialized, cannot remove marker',
      );
      return;
    }

    await _removeMarker(reachId);
  }

  /// Internal method to add a marker
  Future<void> _addMarker(FavoriteRiver favorite) async {
    try {
      // Skip if marker already exists
      if (_heartMarkers.containsKey(favorite.reachId)) {
        return;
      }

      // Create heart marker annotation
      final heartAnnotationOptions = PointAnnotationOptions(
        geometry: Point(
          coordinates: Position(favorite.longitude!, favorite.latitude!),
        ),
        textField: '❤️',
        textSize: 20.0,
        textColor: Colors.red.value,
        textHaloColor: Colors.white.value,
        textHaloWidth: 2.0,
        textOffset: [0.0, -0.5], // Slight offset to center better
      );

      // Add to map using the annotation manager
      final annotation = await _annotationManager!.create(
        heartAnnotationOptions,
      );

      // Track the marker
      _heartMarkers[favorite.reachId] = annotation;
      _currentMarkerReachIds.add(favorite.reachId);

      AppLogger.info('MapMarkerService', 'Added heart marker for ${favorite.reachId}');
    } catch (e) {
      AppLogger.error(
        'MapMarkerService',
        'Error adding marker for ${favorite.reachId}',
        e,
      );
    }
  }

  /// Internal method to remove a marker
  Future<void> _removeMarker(String reachId) async {
    try {
      final annotation = _heartMarkers[reachId];
      if (annotation == null) {
        return; // Marker doesn't exist
      }

      // Remove from map
      await _annotationManager!.delete(annotation);

      // Remove from tracking
      _heartMarkers.remove(reachId);
      _currentMarkerReachIds.remove(reachId);

      AppLogger.info('MapMarkerService', 'Removed heart marker for $reachId');
    } catch (e) {
      AppLogger.error('MapMarkerService', 'Error removing marker for $reachId', e);
    }
  }

  /// Get markers currently in viewport (for lazy loading optimization)
  /// This can be used when there are many favorites to only show markers in view
  Future<List<String>> getMarkersInViewport() async {
    if (!_isInitialized || _mapboxMap == null) {
      return [];
    }

    try {
      // Filter markers that are in viewport
      final markersInView = <String>[];
      for (final entry in _heartMarkers.entries) {
        final reachId = entry.key;
        // Find the favorite to get coordinates
        // This is a simplified approach - in practice you might want to cache coordinates
        // For now, assume all current markers are in reasonable view distance
        markersInView.add(reachId);
      }

      return markersInView;
    } catch (e) {
      AppLogger.error('MapMarkerService', 'Error getting viewport markers', e);
      return [];
    }
  }

  /// Update markers based on viewport (lazy loading)
  /// Only show markers that are in or near the current viewport
  Future<void> updateMarkersForViewport(
    List<FavoriteRiver> allFavorites,
  ) async {
    if (!_isInitialized) return;

    try {
      // Get map bounds with some padding for smoother experience
      final bounds = await _mapboxMap!.getBounds();
      final southwest = bounds.bounds.southwest;
      final northeast = bounds.bounds.northeast;

      // Add some padding to show markers just outside viewport
      const padding = 0.1; // degrees
      final minLat = southwest.coordinates.lat - padding;
      final maxLat = northeast.coordinates.lat + padding;
      final minLng = southwest.coordinates.lng - padding;
      final maxLng = northeast.coordinates.lng + padding;

      // Filter favorites that should be visible
      final visibleFavorites = allFavorites.where((favorite) {
        if (!favorite.hasCoordinates) return false;

        final lat = favorite.latitude!;
        final lng = favorite.longitude!;

        return lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng;
      }).toList();

      // Update markers to only show visible ones
      await updateHeartMarkers(visibleFavorites);

      AppLogger.debug(
        'MapMarkerService',
        'Updated markers for viewport: ${visibleFavorites.length} visible',
      );
    } catch (e) {
      AppLogger.error('MapMarkerService', 'Error updating viewport markers', e);
    }
  }

  /// Clear all markers
  Future<void> clearAllMarkers() async {
    if (!_isInitialized || _annotationManager == null) return;

    try {
      // Remove all markers
      for (final reachId in _currentMarkerReachIds.toList()) {
        await _removeMarker(reachId);
      }

      AppLogger.info('MapMarkerService', 'Cleared all markers');
    } catch (e) {
      AppLogger.error('MapMarkerService', 'Error clearing markers', e);
    }
  }

  /// Get current marker count
  int get markerCount => _heartMarkers.length;

  /// Check if service is ready
  bool get isInitialized => _isInitialized && _annotationManager != null;

  /// Dispose of the service and clean up resources
  void dispose() {
    AppLogger.debug('MapMarkerService', 'Disposing marker service');

    _heartMarkers.clear();
    _currentMarkerReachIds.clear();
    _currentFavorites.clear(); // NEW: Clear stored favorites
    _annotationManager = null;
    _mapboxMap = null;
    _isInitialized = false;

    AppLogger.info('MapMarkerService', 'Marker service disposed');
  }
}
