// lib/core/providers/favorites_provider.dart

import 'package:flutter/foundation.dart';
import 'package:rivrflow/core/models/reach_data.dart';
import '../models/favorite_river.dart';
import '../services/favorites_service.dart';
import '../services/forecast_service.dart';

/// State management for user's favorite rivers
/// Works with cloud-based favorites (reach IDs only) and manages rich data in memory
class FavoritesProvider with ChangeNotifier {
  final FavoritesService _favoritesService = FavoritesService();
  final ForecastService _forecastService = ForecastService();

  // Current state
  List<FavoriteRiver> _favorites = [];
  Set<String> _favoriteReachIds = {}; // O(1) lookup for isFavorite()
  bool _isLoading = false;
  String? _errorMessage;

  // Session data (not persisted, loaded fresh each session)
  final Map<String, String> _sessionRiverNames = {}; // reachId -> riverName
  final Map<String, double?> _sessionFlowData = {}; // reachId -> lastKnownFlow
  final Map<String, DateTime> _sessionFlowUpdates =
      {}; // reachId -> lastUpdated
  final Map<String, ({double lat, double lon})> _sessionCoordinates =
      {}; // reachId -> coordinates

  // Track loading state per favorite for individual refresh indicators
  final Set<String> _refreshingReachIds = {};

  // Getters
  List<FavoriteRiver> get favorites => _buildEnrichedFavorites();
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  int get favoritesCount => _favoriteReachIds.length;
  bool get isEmpty => _favoriteReachIds.isEmpty;
  bool get shouldShowSearch => _favoriteReachIds.length >= 4;

  /// Build enriched favorites list combining cloud data + session data
  List<FavoriteRiver> _buildEnrichedFavorites() {
    return _favorites.map((favorite) {
      final reachId = favorite.reachId;
      return favorite.copyWith(
        riverName: _sessionRiverNames[reachId],
        lastKnownFlow: _sessionFlowData[reachId],
        lastUpdated: _sessionFlowUpdates[reachId],
        latitude: _sessionCoordinates[reachId]?.lat,
        longitude: _sessionCoordinates[reachId]?.lon,
      );
    }).toList();
  }

  /// Check if a specific favorite is being refreshed
  bool isRefreshing(String reachId) => _refreshingReachIds.contains(reachId);

  /// Check if a reach is favorited - O(1) lookup
  bool isFavorite(String reachId) {
    return _favoriteReachIds.contains(reachId);
  }

  /// Get favorites that have coordinates for map markers
  List<FavoriteRiver> getFavoritesWithCoordinates() {
    return favorites.where((f) => f.hasCoordinates).toList();
  }

  /// Compare favorites lists and return what changed for efficient marker updates
  Map<String, dynamic> diffFavorites(List<FavoriteRiver> oldFavorites) {
    final oldReachIds = oldFavorites.map((f) => f.reachId).toSet();
    final newReachIds = _favoriteReachIds;

    return {
      'added': newReachIds.difference(oldReachIds).toList(),
      'removed': oldReachIds.difference(newReachIds).toList(),
    };
  }

  /// Initialize favorites and start background refresh
  Future<void> initializeAndRefresh() async {
    print('FAVORITES_PROVIDER: Initializing favorites with cloud storage');

    _setLoading(true);
    _clearError();

    try {
      // Load favorites from cloud storage first
      await _loadFavoritesFromStorage();

      // Start background refresh after short delay (let UI show cached data)
      Future.delayed(const Duration(milliseconds: 500), () {
        _refreshAllFavoritesInBackground();
      });
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error during initialization: $e');
      _setError(e.toString());
    } finally {
      _setLoading(false);
    }
  }

  /// Load favorites from cloud storage (reach IDs only)
  Future<void> _loadFavoritesFromStorage() async {
    try {
      _favorites = await _favoritesService.loadFavorites();
      _updateFavoriteReachIds(); // Update lookup set
      print(
        'FAVORITES_PROVIDER: ✅ Loaded ${_favorites.length} favorites from cloud',
      );
      notifyListeners();
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error loading favorites: $e');
      rethrow;
    }
  }

  /// Update the lookup set when favorites list changes
  void _updateFavoriteReachIds() {
    _favoriteReachIds = _favorites.map((f) => f.reachId).toSet();
  }

  /// Add a new favorite river (coordinates loaded in background)
  Future<bool> addFavorite(String reachId, {String? customName}) async {
    print('FAVORITES_PROVIDER: Adding favorite: $reachId');

    try {
      // Check if already exists using O(1) lookup
      if (isFavorite(reachId)) {
        print('FAVORITES_PROVIDER: ⚠️ Reach $reachId already favorited');
        return false;
      }

      // Add to cloud storage (reach ID only)
      final success = await _favoritesService.addFavorite(reachId);
      if (!success) return false;

      // Reload from storage to get updated list
      await _loadFavoritesFromStorage();

      // Load rich data in background
      _loadFavoriteDataInBackground(reachId);

      print('FAVORITES_PROVIDER: ✅ Added favorite: $reachId');
      return true;
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error adding favorite: $e');
      _setError(e.toString());
      return false;
    }
  }

  /// Add favorite with known coordinates (avoids duplicate loading)
  Future<bool> addFavoriteWithKnownCoordinates(
    String reachId, {
    String? customName,
    required double latitude,
    required double longitude,
    String? riverName,
  }) async {
    print(
      'FAVORITES_PROVIDER: Adding favorite with known coordinates: $reachId',
    );

    try {
      // Check if already exists using O(1) lookup
      if (isFavorite(reachId)) {
        print('FAVORITES_PROVIDER: ⚠️ Reach $reachId already favorited');
        return false;
      }

      // Add to cloud storage (reach ID only)
      final success = await _favoritesService.addFavorite(reachId);
      if (!success) return false;

      // Store rich data in session storage
      _sessionCoordinates[reachId] = (lat: latitude, lon: longitude);
      if (riverName != null) {
        _sessionRiverNames[reachId] = riverName;
      }

      // Reload from storage to get updated list
      await _loadFavoritesFromStorage();

      // Load remaining data in background if needed
      if (riverName == null) {
        _loadFavoriteRiverNameInBackground(reachId);
      }

      print(
        'FAVORITES_PROVIDER: ✅ Added favorite with known coordinates: $reachId',
      );
      return true;
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error adding favorite with coordinates: $e');
      _setError(e.toString());
      return false;
    }
  }

  /// Load only river name in background (lightweight)
  Future<void> _loadFavoriteRiverNameInBackground(String reachId) async {
    try {
      // Use the lightweight overview data loading
      final forecast = await _forecastService.loadOverviewData(reachId);

      // Store in session data
      _sessionRiverNames[reachId] = forecast.reach.riverName;

      print(
        'FAVORITES_PROVIDER: ✅ Updated river name for $reachId: ${forecast.reach.riverName}',
      );
      notifyListeners();
    } catch (e) {
      print(
        'FAVORITES_PROVIDER: ⚠️ Failed to load river name for $reachId: $e',
      );
      // This is not critical, so don't throw
    }
  }

  /// Remove a favorite river
  Future<bool> removeFavorite(String reachId) async {
    print('FAVORITES_PROVIDER: Removing favorite: $reachId');

    try {
      final success = await _favoritesService.removeFavorite(reachId);
      if (!success) return false;

      // Clean up session data
      _sessionRiverNames.remove(reachId);
      _sessionFlowData.remove(reachId);
      _sessionFlowUpdates.remove(reachId);
      _sessionCoordinates.remove(reachId);
      _refreshingReachIds.remove(reachId);

      // Reload from storage
      await _loadFavoritesFromStorage();

      print('FAVORITES_PROVIDER: ✅ Removed favorite: $reachId');
      return true;
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error removing favorite: $e');
      _setError(e.toString());
      return false;
    }
  }

  /// Reorder favorites (for drag-and-drop)
  Future<bool> reorderFavorites(int oldIndex, int newIndex) async {
    print(
      'FAVORITES_PROVIDER: Reordering favorite from $oldIndex to $newIndex',
    );

    try {
      // Update local list immediately for UI responsiveness
      final reorderedFavorites = List<FavoriteRiver>.from(_favorites);
      final item = reorderedFavorites.removeAt(oldIndex);
      reorderedFavorites.insert(newIndex, item);

      _favorites = reorderedFavorites;
      _updateFavoriteReachIds(); // Update lookup set
      notifyListeners();

      // Persist the reordering
      final success = await _favoritesService.reorderFavorites(_favorites);
      if (!success) {
        // Revert on failure
        await _loadFavoritesFromStorage();
        return false;
      }

      print('FAVORITES_PROVIDER: ✅ Reordered favorites successfully');
      return true;
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error reordering favorites: $e');
      _setError(e.toString());
      await _loadFavoritesFromStorage(); // Revert
      return false;
    }
  }

  /// Update favorite properties (session data only - not persisted)
  Future<bool> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
  }) async {
    print('FAVORITES_PROVIDER: Updating favorite session data: $reachId');

    try {
      // Update session data (not persisted to cloud)
      if (riverName != null) {
        _sessionRiverNames[reachId] = riverName;
      }

      notifyListeners();
      print('FAVORITES_PROVIDER: ✅ Updated favorite session data: $reachId');
      return true;
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error updating favorite: $e');
      _setError(e.toString());
      return false;
    }
  }

  /// Refresh all favorites flow data (pull-to-refresh)
  Future<void> refreshAllFavorites() async {
    print('FAVORITES_PROVIDER: Manual refresh of all favorites');

    _clearError();

    // Clear computed caches to force fresh calculations
    _forecastService.clearComputedCaches();

    // Refresh each favorite
    final refreshTasks = _favorites
        .map((favorite) => _refreshSingleFavorite(favorite.reachId))
        .toList();

    await Future.wait(refreshTasks);
    print('FAVORITES_PROVIDER: ✅ Manual refresh completed');
  }

  /// Background refresh of all favorites (app launch)
  Future<void> _refreshAllFavoritesInBackground() async {
    print(
      'FAVORITES_PROVIDER: Starting background refresh of ${_favorites.length} favorites',
    );

    // Refresh favorites one by one to show progressive updates
    for (final favorite in _favorites) {
      await _refreshSingleFavorite(favorite.reachId);
      // Small delay between requests to be API-friendly
      await Future.delayed(const Duration(milliseconds: 200));
    }

    print('FAVORITES_PROVIDER: ✅ Background refresh completed');
  }

  /// Load favorite data in background (when new favorite added)
  Future<void> _loadFavoriteDataInBackground(String reachId) async {
    await _refreshSingleFavorite(reachId);
  }

  /// Ultra-fast favorite addition for map integration
  Future<bool> addFavoriteFromMap(String reachId, {String? customName}) async {
    print('FAVORITES_PROVIDER: Adding favorite from map: $reachId');

    try {
      // Check if already exists using O(1) lookup
      if (isFavorite(reachId)) {
        print('FAVORITES_PROVIDER: ⚠️ Reach $reachId already favorited');
        return false;
      }

      // Get basic reach info only (ultra-fast)
      ReachData reach;
      try {
        reach = await _forecastService.loadBasicReachInfo(reachId);
        print('FAVORITES_PROVIDER: ✅ Got basic info for $reachId');
      } catch (e) {
        print(
          'FAVORITES_PROVIDER: ❌ Could not get basic info for $reachId: $e',
        );
        return false;
      }

      // Add to cloud storage (reach ID only)
      final success = await _favoritesService.addFavorite(reachId);
      if (!success) return false;

      // Store session data
      _sessionCoordinates[reachId] = (
        lat: reach.latitude,
        lon: reach.longitude,
      );

      // Reload from storage to get updated list
      await _loadFavoritesFromStorage();

      // Load flow data in background (non-blocking)
      Future.delayed(const Duration(milliseconds: 100), () {
        _loadFavoriteDataInBackground(reachId);
      });

      print('FAVORITES_PROVIDER: ✅ Added favorite from map: $reachId');
      return true;
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error adding favorite from map: $e');
      _setError(e.toString());
      return false;
    }
  }

  /// Refresh a single favorite's flow data and store in session
  Future<void> _refreshSingleFavorite(String reachId) async {
    try {
      _refreshingReachIds.add(reachId);
      notifyListeners();

      // Load efficient data for favorites refresh
      final forecast = await _forecastService.loadCurrentFlowOnly(reachId);
      final currentFlow = _forecastService.getCurrentFlow(forecast);

      // Store all data in session storage (not persisted to cloud)
      _sessionRiverNames[reachId] = forecast.reach.riverName;
      _sessionFlowData[reachId] = currentFlow;
      _sessionFlowUpdates[reachId] = DateTime.now();
      _sessionCoordinates[reachId] = (
        lat: forecast.reach.latitude,
        lon: forecast.reach.longitude,
      );

      print('FAVORITES_PROVIDER: ✅ Refreshed session data for $reachId');
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Failed to refresh $reachId: $e');
      // Individual failures don't break the whole list
    } finally {
      _refreshingReachIds.remove(reachId);
      notifyListeners();
    }
  }

  /// Filter favorites by search query
  List<FavoriteRiver> filterFavorites(String query) {
    if (query.isEmpty) return favorites;

    final lowerQuery = query.toLowerCase();
    return favorites.where((favorite) {
      return favorite.displayName.toLowerCase().contains(lowerQuery) ||
          favorite.reachId.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  // Helper methods
  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _setError(String error) {
    _errorMessage = error;
    notifyListeners();
  }

  void _clearError() {
    _errorMessage = null;
  }

  /// Clear all favorites (for testing)
  Future<void> clearAllFavorites() async {
    await _favoritesService.clearAllFavorites();

    // Clear all data
    _favorites.clear();
    _favoriteReachIds.clear();
    _refreshingReachIds.clear();
    _sessionRiverNames.clear();
    _sessionFlowData.clear();
    _sessionFlowUpdates.clear();
    _sessionCoordinates.clear();

    _clearError();
    notifyListeners();
    print('FAVORITES_PROVIDER: ✅ Cleared all favorites and session data');
  }

  /// Get just the reach IDs for notification system
  List<String> get favoriteReachIds =>
      _favorites.map((f) => f.reachId).toList();
}
