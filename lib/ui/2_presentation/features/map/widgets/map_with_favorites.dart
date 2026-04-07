// lib/ui/2_presentation/features/map/widgets/map_with_favorites.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/2_presentation/features/map/pages/map_page.dart';

/// Wrapper widget that coordinates between FavoritesProvider and MapPage
/// Handles favorites changes and updates map markers efficiently
/// Keeps MapPage clean and focused only on map functionality
class MapWithFavorites extends StatefulWidget {
  const MapWithFavorites({super.key});

  @override
  State<MapWithFavorites> createState() => _MapWithFavoritesState();
}

class _MapWithFavoritesState extends State<MapWithFavorites> {
  final GlobalKey<MapPageState> _mapPageKey = GlobalKey<MapPageState>();

  // Track previous favorites to avoid unnecessary updates
  List<String> _previousFavoriteIds = [];

  @override
  Widget build(BuildContext context) {
    return Consumer<FavoritesProvider>(
      builder: (context, favoritesProvider, child) {
        // Schedule marker update after build to avoid calling setState during build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleFavoritesChange(favoritesProvider);
        });

        return MapPage(key: _mapPageKey);
      },
    );
  }

  /// Handle changes in favorites and update map markers efficiently
  void _handleFavoritesChange(FavoritesProvider favoritesProvider) {
    // Check if map and marker service are ready
    final mapPageState = _mapPageKey.currentState;
    if (mapPageState == null || !mapPageState.markerService.isInitialized) {
      AppLogger.debug('MapWithFavorites', 'Map not ready for marker updates');
      return;
    }

    // Get current favorites with coordinates
    final currentFavorites = favoritesProvider.getFavoritesWithCoordinates();
    final currentFavoriteIds = currentFavorites.map((f) => f.reachId).toList();

    // Check if favorites actually changed to avoid unnecessary updates
    if (_haveFavoritesChanged(currentFavoriteIds)) {
      AppLogger.debug(
        'MapWithFavorites',
        'Favorites changed, updating ${currentFavorites.length} markers',
      );

      // Update markers using the efficient marker service
      mapPageState.markerService.updateHeartMarkers(currentFavorites);

      // Update tracking
      _previousFavoriteIds = currentFavoriteIds;
    }
  }

  /// Check if favorites list has actually changed
  bool _haveFavoritesChanged(List<String> currentIds) {
    // Quick length check
    if (_previousFavoriteIds.length != currentIds.length) {
      return true;
    }

    // Check if any IDs are different
    final previousSet = _previousFavoriteIds.toSet();
    final currentSet = currentIds.toSet();

    return !previousSet.containsAll(currentSet) ||
        !currentSet.containsAll(previousSet);
  }

  @override
  void initState() {
    super.initState();

    // Initialize markers after the first frame when provider is available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeMarkersWhenReady();
    });
  }

  /// Initialize markers when both map and favorites provider are ready
  void _initializeMarkersWhenReady() async {
    // Wait for map to be ready
    int attempts = 0;
    const maxAttempts = 10;
    const delayMs = 500;

    while (attempts < maxAttempts) {
      final mapPageState = _mapPageKey.currentState;
      if (mapPageState?.markerService.isInitialized == true) {
        AppLogger.debug('MapWithFavorites', 'Map ready, loading initial markers');

        // Get favorites provider and load initial markers
        if (mounted) {
          final favoritesProvider = context.read<FavoritesProvider>();
          _handleFavoritesChange(favoritesProvider);
        }
        break;
      }

      attempts++;
      await Future.delayed(const Duration(milliseconds: delayMs));

      if (!mounted) break; // Exit if widget was disposed
    }

    if (attempts >= maxAttempts) {
      AppLogger.warning('MapWithFavorites', 'Timeout waiting for map to initialize');
    }
  }

  @override
  void dispose() {
    // Clear any stored state
    _previousFavoriteIds.clear();
    super.dispose();
  }
}
