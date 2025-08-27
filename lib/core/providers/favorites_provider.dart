// lib/core/providers/favorites_provider.dart

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:rivrflow/core/models/reach_data.dart';
import 'package:rivrflow/core/services/noaa_api_service.dart';
import 'package:rivrflow/core/services/reach_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/favorite_river.dart';
import '../services/favorites_service.dart';
import '../services/forecast_service.dart';
import '../services/flow_unit_preference_service.dart';

/// State management for user's favorite rivers
/// Works with cloud-based favorites (reach IDs only) and manages rich data in memory
/// FIXED: Added unit tracking to prevent double conversion
class FavoritesProvider with ChangeNotifier {
  final FavoritesService _favoritesService = FavoritesService();
  final ForecastService _forecastService = ForecastService();
  final ReachCacheService _reachCacheService = ReachCacheService();
  final Map<String, Map<int, double>> _sessionReturnPeriods =
      {}; // reachId -> return periods

  // Current state
  List<FavoriteRiver> _favorites = [];
  Set<String> _favoriteReachIds = {}; // O(1) lookup for isFavorite()
  bool _isLoading = false;
  String? _errorMessage;

  // Session data (not persisted, loaded fresh each session)
  final Map<String, String> _sessionRiverNames = {}; // reachId -> riverName
  final Map<String, double?> _sessionFlowData = {}; // reachId -> lastKnownFlow
  final Map<String, String> _sessionFlowUnits =
      {}; // reachId -> unit of stored flow
  final Map<String, DateTime> _sessionFlowUpdates =
      {}; // reachId -> lastUpdated
  final Map<String, ({double lat, double lon})> _sessionCoordinates =
      {}; // reachId -> coordinates

  // Session data maps to store custom properties
  final Map<String, String> _sessionCustomNames = {}; // reachId -> customName
  final Map<String, String> _sessionCustomImages =
      {}; // reachId -> customImageAsset

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
  /// FIXED: Now passes stored unit information
  List<FavoriteRiver> _buildEnrichedFavorites() {
    return _favorites.map((favorite) {
      final reachId = favorite.reachId;
      return favorite.copyWith(
        riverName: _sessionRiverNames[reachId],
        customName: _sessionCustomNames[reachId],
        customImageAsset: _sessionCustomImages[reachId],
        lastKnownFlow: _sessionFlowData[reachId],
        storedFlowUnit:
            _sessionFlowUnits[reachId], // CRITICAL FIX: Pass stored unit
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
    _setLoading(true);
    _clearError();

    try {
      // Load favorites from cloud storage first
      await _loadFavoritesFromStorage();

      // LOAD CUSTOM PROPERTIES FROM LOCAL STORAGE
      await _loadCustomPropertiesFromLocal();

      // Start background refresh after short delay (let UI show cached data)
      Future.delayed(const Duration(milliseconds: 500), () {
        _refreshAllFavoritesInBackground();
      });
    } catch (e) {
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
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  /// Update the lookup set when favorites list changes
  void _updateFavoriteReachIds() {
    _favoriteReachIds = _favorites.map((f) => f.reachId).toSet();
  }

  /// Add a new favorite river (coordinates loaded in background)
  Future<bool> addFavorite(String reachId, {String? customName}) async {
    try {
      // Check if already exists using O(1) lookup
      if (isFavorite(reachId)) {
        return false;
      }

      // Add to cloud storage (reach ID only)
      final success = await _favoritesService.addFavorite(reachId);
      if (!success) return false;

      // Reload from storage to get updated list
      await _loadFavoritesFromStorage();

      // Load rich data in background
      _loadFavoriteDataInBackground(reachId);

      return true;
    } catch (e) {
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
    try {
      // Check if already exists using O(1) lookup
      if (isFavorite(reachId)) {
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

      return true;
    } catch (e) {
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

      notifyListeners();
    } catch (e) {
      print(
        'FAVORITES_PROVIDER: ⚠️ Failed to load river name for $reachId: $e',
      );
      // This is not critical, so don't throw
    }
  }

  /// Remove a favorite river and clean up custom properties when favorite is removed
  /// FIXED: Also clean up stored flow units
  Future<bool> removeFavorite(String reachId) async {
    try {
      final success = await _favoritesService.removeFavorite(reachId);
      if (!success) return false;

      // Clean up ALL session data including custom properties
      _sessionRiverNames.remove(reachId);
      _sessionFlowData.remove(reachId);
      _sessionFlowUnits.remove(
        reachId,
      ); // FIXED: Clean up stored flow units too
      _sessionFlowUpdates.remove(reachId);
      _sessionCoordinates.remove(reachId);
      _sessionCustomNames.remove(reachId);
      _sessionCustomImages.remove(reachId);
      _refreshingReachIds.remove(reachId);

      // PERSIST CHANGES TO LOCAL STORAGE
      await _persistCustomPropertiesToLocal();

      // Reload from storage
      await _loadFavoritesFromStorage();

      return true;
    } catch (e) {
      _setError(e.toString());
      return false;
    }
  }

  /// Reorder favorites (for drag-and-drop)
  Future<bool> reorderFavorites(int oldIndex, int newIndex) async {
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

      return true;
    } catch (e) {
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
    try {
      // Update session data (stored locally)
      if (riverName != null) {
        _sessionRiverNames[reachId] = riverName;
      }

      // HANDLES CUSTOM NAME
      if (customName != null) {
        _sessionCustomNames[reachId] = customName;
      }

      if (customImageAsset != null) {
        _sessionCustomImages[reachId] = customImageAsset;
      } else {
        // Explicitly handle null to remove custom image
        _sessionCustomImages.remove(reachId);
      }

      // PERSISTS TO LOCAL STORAGE
      await _persistCustomPropertiesToLocal();

      notifyListeners();
      return true;
    } catch (e) {
      _setError(e.toString());
      return false;
    }
  }

  /// Persist custom properties to SharedPreferences for persistence across app restarts
  Future<void> _persistCustomPropertiesToLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Convert maps to JSON and save
      await prefs.setString(
        'favorites_custom_names',
        json.encode(_sessionCustomNames),
      );
      await prefs.setString(
        'favorites_custom_images',
        json.encode(_sessionCustomImages),
      );
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error persisting custom properties: $e');
    }
  }

  /// Load custom properties from SharedPreferences on app start
  Future<void> _loadCustomPropertiesFromLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load custom names
      final namesJson = prefs.getString('favorites_custom_names');
      if (namesJson != null) {
        final namesMap = json.decode(namesJson) as Map<String, dynamic>;
        _sessionCustomNames.addAll(namesMap.cast<String, String>());
      }

      // Load custom images
      final imagesJson = prefs.getString('favorites_custom_images');
      if (imagesJson != null) {
        final imagesMap = json.decode(imagesJson) as Map<String, dynamic>;
        _sessionCustomImages.addAll(imagesMap.cast<String, String>());
      }
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Error loading custom properties: $e');
    }
  }

  /// Refresh all favorites flow data (pull-to-refresh)
  Future<void> refreshAllFavorites() async {
    _clearError();

    // Clear computed caches to force fresh calculations
    _forecastService.clearComputedCaches();

    // Refresh each favorite
    final refreshTasks = _favorites
        .map((favorite) => _refreshSingleFavorite(favorite.reachId))
        .toList();

    await Future.wait(refreshTasks);
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

    print('FAVORITES_PROVIDER: Background refresh completed');
  }

  /// Load favorite data in background (when new favorite added)
  Future<void> _loadFavoriteDataInBackground(String reachId) async {
    await _refreshSingleFavorite(reachId);
  }

  /// Ultra-fast favorite addition for map integration
  Future<bool> addFavoriteFromMap(String reachId, {String? customName}) async {
    try {
      // Check if already exists using O(1) lookup
      if (isFavorite(reachId)) {
        return false;
      }

      // Get basic reach info only (ultra-fast)
      ReachData reach;
      try {
        reach = await _forecastService.loadBasicReachInfo(reachId);
      } catch (e) {
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

      return true;
    } catch (e) {
      _setError(e.toString());
      return false;
    }
  }

  /// Refresh a single favorite's flow data and store in session
  /// FIXED: Now tracks units of stored flow values
  Future<void> _refreshSingleFavorite(String reachId) async {
    try {
      _refreshingReachIds.add(reachId);
      notifyListeners();

      // Load efficient data for favorites refresh
      final forecast = await _forecastService.loadCurrentFlowOnly(reachId);
      final currentFlow = _forecastService.getCurrentFlow(forecast);

      // CRITICAL FIX: Store the current flow unit along with the value
      final currentUnit = FlowUnitPreferenceService().currentFlowUnit;

      // Store all data in session storage (not persisted to cloud)
      _sessionRiverNames[reachId] = forecast.reach.riverName;
      _sessionFlowData[reachId] = currentFlow;
      _sessionFlowUnits[reachId] =
          currentUnit; // FIXED: Track what unit the stored flow is in
      _sessionFlowUpdates[reachId] = DateTime.now();
      _sessionCoordinates[reachId] = (
        lat: forecast.reach.latitude,
        lon: forecast.reach.longitude,
      );

      // Load return periods for this favorite
      await _loadReturnPeriods(reachId);

      // Print results for this favorite - FIXED: Use correct unit in display
      final flow = _sessionFlowData[reachId];
      final riverName = _sessionRiverNames[reachId] ?? 'Unknown';
      final returnPeriods = _sessionReturnPeriods[reachId];

      print(
        'FAVORITES_PROVIDER: $riverName ($reachId) - Current Flow: ${flow?.toStringAsFixed(1) ?? 'No data'} $currentUnit',
      ); // FIXED: Use actual current unit, not hardcoded "CFS"

      if (returnPeriods != null && returnPeriods.isNotEmpty) {
        print(
          'FAVORITES_PROVIDER: $riverName ($reachId) - Return Periods: ${returnPeriods.toString()}',
        );
      } else {
        print(
          'FAVORITES_PROVIDER: $riverName ($reachId) - No return periods available',
        );
      }
    } catch (e) {
      print('FAVORITES_PROVIDER: ❌ Failed to refresh $reachId: $e');
    } finally {
      _refreshingReachIds.remove(reachId);
      notifyListeners();
    }
  }

  /// Get return periods for a specific favorite
  Map<int, double>? getReturnPeriods(String reachId) {
    return _sessionReturnPeriods[reachId];
  }

  /// Load return periods for a favorite (with caching)
  Future<void> _loadReturnPeriods(String reachId) async {
    try {
      // Check cache first
      final cachedReach = await _reachCacheService.get(reachId);

      if (cachedReach?.hasReturnPeriods == true) {
        _sessionReturnPeriods[reachId] = cachedReach!.returnPeriods!;
        print('FAVORITES_PROVIDER: Using cached return periods for $reachId');
        return;
      }

      // Fetch fresh return periods
      final returnPeriods = await NoaaApiService().fetchReturnPeriods(reachId);

      if (returnPeriods.isNotEmpty) {
        // Parse return periods
        final returnPeriodData = ReachData.fromReturnPeriodApi(returnPeriods);
        _sessionReturnPeriods[reachId] = returnPeriodData.returnPeriods!;

        // Cache for future use
        if (cachedReach != null) {
          final updatedReach = cachedReach.mergeWith(returnPeriodData);
          await _reachCacheService.store(updatedReach);
        }
      }
    } catch (e) {
      print(
        'FAVORITES_PROVIDER: ⚠️ Failed to load return periods for $reachId: $e',
      );
      // Continue without return periods
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

  /// Clear unit-dependent cached values (call when unit preference changes)
  /// FIXED: Also clear stored flow units when units change
  void clearUnitDependentCaches() {
    print('FAVORITES_PROVIDER: Clearing unit-dependent caches for unit change');

    // Clear flow data and their associated units since they need to be re-fetched
    _sessionFlowData.clear();
    _sessionFlowUnits.clear(); // FIXED: Clear unit tracking too
    _sessionFlowUpdates
        .clear(); // Also clear update timestamps to force refresh

    // Notify UI immediately of the change
    notifyListeners();

    // Refresh all favorites to get data in new units
    Future.delayed(const Duration(milliseconds: 100), () {
      refreshAllFavorites(); // Use public method for proper error handling
    });
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
    _sessionFlowUnits.clear(); // FIXED: Clear flow units too
    _sessionFlowUpdates.clear();
    _sessionCoordinates.clear();

    _clearError();
    notifyListeners();
  }

  /// Get just the reach IDs for notification system
  List<String> get favoriteReachIds =>
      _favorites.map((f) => f.reachId).toList();
}
