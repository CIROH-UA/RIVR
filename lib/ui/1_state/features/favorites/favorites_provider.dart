// lib/ui/1_state/features/favorites/favorites_provider.dart

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/favorite_session_data.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/shared/analytics_service.dart';
import 'package:rivr/models/2_usecases/features/favorites/initialize_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/add_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/remove_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/reorder_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/get_favorite_flow_usecase.dart';

/// State management for user's favorite rivers
/// Works with cloud-based favorites (reach IDs only) and manages rich data in memory
class FavoritesProvider with ChangeNotifier {
  // Use cases for CRUD operations
  final InitializeFavoritesUseCase _initializeFavorites;
  final AddFavoriteUseCase _addFavoriteUseCase;
  final RemoveFavoriteUseCase _removeFavoriteUseCase;
  final ReorderFavoritesUseCase _reorderFavoritesUseCase;
  final GetFavoriteFlowUseCase _getFavoriteFlowUseCase;

  // Services kept for cross-cutting concerns
  final IFavoritesService _favoritesService;
  final IForecastService _forecastService;
  final IReachCacheService _reachCacheService;
  final IFlowUnitPreferenceService _unitService;
  final Map<String, Map<int, double>> _sessionReturnPeriods =
      {}; // reachId -> return periods

  FavoritesProvider({
    IFavoritesService? favoritesService,
    IForecastService? forecastService,
    IReachCacheService? reachCacheService,
    IFlowUnitPreferenceService? unitService,
    InitializeFavoritesUseCase? initializeFavorites,
    AddFavoriteUseCase? addFavoriteUseCase,
    RemoveFavoriteUseCase? removeFavoriteUseCase,
    ReorderFavoritesUseCase? reorderFavoritesUseCase,
    GetFavoriteFlowUseCase? getFavoriteFlowUseCase,
  })  : _favoritesService = favoritesService ?? GetIt.I<IFavoritesService>(),
        _forecastService = forecastService ?? GetIt.I<IForecastService>(),
        _reachCacheService =
            reachCacheService ?? GetIt.I<IReachCacheService>(),
        _unitService =
            unitService ?? GetIt.I<IFlowUnitPreferenceService>(),
        _initializeFavorites =
            initializeFavorites ?? GetIt.I<InitializeFavoritesUseCase>(),
        _addFavoriteUseCase =
            addFavoriteUseCase ?? GetIt.I<AddFavoriteUseCase>(),
        _removeFavoriteUseCase =
            removeFavoriteUseCase ?? GetIt.I<RemoveFavoriteUseCase>(),
        _reorderFavoritesUseCase =
            reorderFavoritesUseCase ?? GetIt.I<ReorderFavoritesUseCase>(),
        _getFavoriteFlowUseCase =
            getFavoriteFlowUseCase ?? GetIt.I<GetFavoriteFlowUseCase>();

  // Current state
  List<FavoriteRiver> _favorites = [];
  Set<String> _favoriteReachIds = {}; // O(1) lookup for isFavorite()
  bool _isLoading = false;
  String? _errorMessage;

  // Consolidated session data per favorite (replaces 7 parallel maps)
  final Map<String, FavoriteSessionData> _sessionData = {};

  // Track loading state per favorite for individual refresh indicators
  final Set<String> _refreshingReachIds = {};

  // Generation counters — prevent stale in-flight results from being applied.
  // Per-reach counter for individual refreshes; top-level for refreshAll.
  final Map<String, int> _refreshGenerations = {};
  int _refreshAllGeneration = 0;

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
      final session = _sessionData[reachId];
      if (session == null) return favorite;
      return favorite.copyWith(
        riverName: session.riverName,
        customName: session.customName,
        customImageAsset: session.customImageAsset,
        lastKnownFlow: session.lastKnownFlow,
        storedFlowUnit: session.flowUnit,
        lastUpdated: session.lastUpdated,
        latitude: session.coordinates?.lat,
        longitude: session.coordinates?.lon,
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

  /// Initialize favorites and start background refresh.
  /// Shows last-known data instantly, then refreshes in background.
  Future<void> initializeAndRefresh() async {
    _setLoading(true);
    _clearError();

    try {
      // 1. Load reach IDs from Firestore via use case
      await _loadFavoritesFromStorage();

      // 2. Restore full session data from SharedPreferences (instant display)
      await _loadSessionDataFromLocal();

      // 3. Fill gaps from reach cache (edge case: prefs cleared, cache intact)
      await _enrichFromReachCache();

      // 4. Notify UI so cards show last-known flow immediately
      notifyListeners();

      // 5. Background refresh with batched parallelism
      Future.delayed(const Duration(milliseconds: 500), () {
        _refreshAllFavoritesInBackground();
      });
    } catch (e) {
      _setError(e.toString());
    } finally {
      _setLoading(false);
    }
  }

  /// Load favorites from cloud storage (reach IDs only) via use case
  Future<void> _loadFavoritesFromStorage() async {
    final result = await _initializeFavorites();

    if (result.isFailure) {
      throw Exception(result.errorMessage ?? 'Failed to load favorites');
    }

    _favorites = result.data;
    _updateFavoriteReachIds(); // Update lookup set
    notifyListeners();
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

      // Add to cloud storage via use case
      final result = await _addFavoriteUseCase(reachId);
      if (result.isFailure) {
        _setError(result.errorMessage ?? 'Failed to add favorite');
        return false;
      }
      if (!result.data) return false;

      AnalyticsService.instance.logFavoriteAdded(reachId);

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
    double? currentFlow,
  }) async {
    try {
      // Check if already exists using O(1) lookup
      if (isFavorite(reachId)) {
        return false;
      }

      // Add to cloud storage via use case
      final result = await _addFavoriteUseCase(reachId);
      if (result.isFailure) {
        _setError(result.errorMessage ?? 'Failed to add favorite');
        return false;
      }
      if (!result.data) return false;

      AnalyticsService.instance.logFavoriteAdded(reachId);

      // Store rich data in session storage
      _sessionData[reachId] = (_sessionData[reachId] ?? FavoriteSessionData.empty).copyWith(
        coordinates: (lat: latitude, lon: longitude),
        riverName: riverName,
        lastKnownFlow: currentFlow,
        flowUnit: currentFlow != null ? _unitService.currentFlowUnit : null,
        lastUpdated: currentFlow != null ? DateTime.now() : null,
      );

      // Reload from storage to get updated list
      await _loadFavoritesFromStorage();

      // Load return periods and remaining data in background
      _loadFavoriteDataInBackground(reachId);

      return true;
    } catch (e) {
      _setError(e.toString());
      return false;
    }
  }

  /// Remove a favorite river and clean up all session data
  Future<bool> removeFavorite(String reachId) async {
    try {
      // Remove from cloud storage via use case
      final result = await _removeFavoriteUseCase(reachId);
      if (result.isFailure) {
        _setError(result.errorMessage ?? 'Failed to remove favorite');
        return false;
      }
      if (!result.data) return false;

      AnalyticsService.instance.logFavoriteRemoved(reachId);

      // Clean up ALL session data in one call
      _sessionData.remove(reachId);
      _sessionReturnPeriods.remove(reachId);
      _refreshingReachIds.remove(reachId);
      _refreshGenerations.remove(reachId);

      // PERSIST CHANGES TO LOCAL STORAGE
      await _persistSessionDataToLocal();

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

      // Persist the reordering via use case
      final result = await _reorderFavoritesUseCase(_favorites);
      if (result.isFailure) {
        // Revert on failure
        await _loadFavoritesFromStorage();
        return false;
      }
      if (!result.data) {
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

  /// Update favorite properties (custom name, image, river name)
  Future<bool> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
  }) async {
    try {
      final existing = _sessionData[reachId] ?? FavoriteSessionData.empty;
      _sessionData[reachId] = existing.copyWith(
        riverName: riverName,
        customName: customName,
        // Explicitly handle null to remove custom image
        customImageAsset: customImageAsset,
      );

      // PERSISTS TO LOCAL STORAGE
      await _persistSessionDataToLocal();

      notifyListeners();
      return true;
    } catch (e) {
      _setError(e.toString());
      return false;
    }
  }

  /// Persist full session data to SharedPreferences for instant display on cold start.
  Future<void> _persistSessionDataToLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final dataMap = <String, dynamic>{};
      for (final entry in _sessionData.entries) {
        final jsonVal = entry.value.toJson();
        if (jsonVal.isNotEmpty) {
          dataMap[entry.key] = jsonVal;
        }
      }

      await prefs.setString(
        'favorites_session_data',
        json.encode(dataMap),
      );
    } catch (e) {
      AppLogger.error('FavoritesProvider', 'Error persisting session data: $e', e);
    }
  }

  /// Load full session data from SharedPreferences for instant cold-start display.
  /// Falls back to legacy separate-key format and migrates if needed.
  Future<void> _loadSessionDataFromLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Try new unified format first
      final sessionJson = prefs.getString('favorites_session_data');
      if (sessionJson != null) {
        final dataMap = json.decode(sessionJson) as Map<String, dynamic>;
        for (final entry in dataMap.entries) {
          _sessionData[entry.key] = FavoriteSessionData.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }
        return;
      }

      // Fall back to legacy separate-key format and migrate
      bool migrated = false;

      final namesJson = prefs.getString('favorites_custom_names');
      if (namesJson != null) {
        final namesMap = json.decode(namesJson) as Map<String, dynamic>;
        for (final entry in namesMap.entries) {
          _sessionData[entry.key] = (_sessionData[entry.key] ?? FavoriteSessionData.empty).copyWith(
            customName: entry.value as String,
          );
        }
        migrated = true;
      }

      final imagesJson = prefs.getString('favorites_custom_images');
      if (imagesJson != null) {
        final imagesMap = json.decode(imagesJson) as Map<String, dynamic>;
        for (final entry in imagesMap.entries) {
          _sessionData[entry.key] = (_sessionData[entry.key] ?? FavoriteSessionData.empty).copyWith(
            customImageAsset: entry.value as String,
          );
        }
        migrated = true;
      }

      // Migrate to new format and clean up legacy keys
      if (migrated) {
        await _persistSessionDataToLocal();
        await prefs.remove('favorites_custom_names');
        await prefs.remove('favorites_custom_images');
        AppLogger.debug('FavoritesProvider', 'Migrated legacy custom properties to session data');
      }
    } catch (e) {
      AppLogger.error('FavoritesProvider', 'Error loading session data: $e', e);
    }
  }

  /// Fill gaps in session data from reach cache (covers edge case where
  /// SharedPreferences was cleared but reach cache still has data).
  Future<void> _enrichFromReachCache() async {
    for (final favorite in _favorites) {
      final reachId = favorite.reachId;
      final session = _sessionData[reachId];

      // Only enrich if missing key display fields
      final needsName = session?.riverName == null;
      final needsCoords = session?.coordinates == null;
      if (!needsName && !needsCoords) continue;

      final cached = await _reachCacheService.get(reachId);
      if (cached == null) continue;

      _sessionData[reachId] = (session ?? FavoriteSessionData.empty).copyWith(
        riverName: needsName ? cached.riverName : null,
        coordinates: needsCoords
            ? (lat: cached.latitude, lon: cached.longitude)
            : null,
      );
    }
  }

  /// Refresh all favorites flow data (pull-to-refresh)
  Future<void> refreshAllFavorites() async {
    final gen = ++_refreshAllGeneration;
    _clearError();

    // Clear computed caches to force fresh calculations
    _forecastService.clearComputedCaches();

    // Refresh each favorite — abandon results if a newer refreshAll was started
    final refreshTasks = _favorites.map((favorite) async {
      await _refreshSingleFavorite(favorite.reachId);
      // No-op if a newer refreshAll has superseded this one (individual
      // generation guard already dropped stale data in _refreshSingleFavorite)
    }).toList();

    await Future.wait(refreshTasks);

    // Only notify if still the latest refreshAll
    if (gen == _refreshAllGeneration) notifyListeners();
  }

  /// Background refresh of all favorites (app launch).
  /// Batched parallel (2 at a time) for faster loading without connection exhaustion.
  Future<void> _refreshAllFavoritesInBackground() async {
    AppLogger.debug(
      'FavoritesProvider',
      'Starting background refresh of ${_favorites.length} favorites',
    );

    final reachIds = _favorites.map((f) => f.reachId).toList();
    const batchSize = 2;
    for (var i = 0; i < reachIds.length; i += batchSize) {
      final batch = reachIds.skip(i).take(batchSize);
      await Future.wait(batch.map((id) => _refreshSingleFavorite(id)));
    }

    AppLogger.debug('FavoritesProvider', 'Background refresh completed');
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

      // Add to cloud storage via use case
      final result = await _addFavoriteUseCase(reachId);
      if (result.isFailure) {
        _setError(result.errorMessage ?? 'Failed to add favorite');
        return false;
      }
      if (!result.data) return false;

      AnalyticsService.instance.logFavoriteAdded(reachId);

      // Store session data
      _sessionData[reachId] = (_sessionData[reachId] ?? FavoriteSessionData.empty).copyWith(
        coordinates: (lat: reach.latitude, lon: reach.longitude),
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
  Future<void> _refreshSingleFavorite(String reachId) async {
    final gen = (_refreshGenerations[reachId] ?? 0) + 1;
    _refreshGenerations[reachId] = gen;

    try {
      _refreshingReachIds.add(reachId);
      notifyListeners();

      // Load flow data + return periods via use case (repository handles
      // return period merging, cache fallback, and fresh fetch)
      final result = await _getFavoriteFlowUseCase(reachId);

      // Discard result if a newer refresh for this reach has been started
      if (_refreshGenerations[reachId] != gen) return;

      if (result.isFailure) {
        AppLogger.error(
          'FavoritesProvider',
          'Failed to refresh $reachId: ${result.errorMessage}',
        );
        return;
      }

      final forecast = result.data;
      final currentFlow = _forecastService.getCurrentFlow(forecast);
      final currentUnit = _unitService.currentFlowUnit;

      // Store all data in session storage (preserves custom name/image)
      final existing = _sessionData[reachId] ?? FavoriteSessionData.empty;
      _sessionData[reachId] = existing.copyWith(
        riverName: forecast.reach.riverName,
        lastKnownFlow: currentFlow,
        flowUnit: currentUnit,
        lastUpdated: DateTime.now(),
        coordinates: (lat: forecast.reach.latitude, lon: forecast.reach.longitude),
      );

      // Cache return periods from the forecast response
      if (forecast.reach.hasReturnPeriods) {
        _sessionReturnPeriods[reachId] = forecast.reach.returnPeriods!;
      }

      final session = _sessionData[reachId]!;
      final riverName = session.riverName ?? 'Unknown';
      final returnPeriods = _sessionReturnPeriods[reachId];

      AppLogger.debug(
        'FavoritesProvider',
        '$riverName ($reachId) - Current Flow: ${session.lastKnownFlow?.toStringAsFixed(1) ?? 'No data'} $currentUnit',
      );

      // Persist updated session data after each successful refresh
      _persistSessionDataToLocal();

      if (returnPeriods != null && returnPeriods.isNotEmpty) {
        AppLogger.debug(
          'FavoritesProvider',
          '$riverName ($reachId) - Return Periods: ${returnPeriods.toString()}',
        );
      } else {
        AppLogger.debug(
          'FavoritesProvider',
          '$riverName ($reachId) - No return periods available',
        );
      }
    } catch (e) {
      AppLogger.error('FavoritesProvider', 'Failed to refresh $reachId: $e', e);
    } finally {
      _refreshingReachIds.remove(reachId);
      notifyListeners();
    }
  }

  /// Get return periods for a specific favorite
  Map<int, double>? getReturnPeriods(String reachId) {
    return _sessionReturnPeriods[reachId];
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
    if (_isLoading != loading) {
      _isLoading = loading;
      notifyListeners();
    }
  }

  void _setError(String error) {
    if (_errorMessage != error) {
      _errorMessage = error;
      notifyListeners();
    }
  }

  void _clearError() {
    _errorMessage = null;
  }

  /// Clear unit-dependent cached values (call when unit preference changes).
  /// Flow data is preserved — formattedFlow and flood risk category convert
  /// from storedFlowUnit to the current preference at render time.
  void clearUnitDependentCaches() {
    AppLogger.debug('FavoritesProvider', 'Unit changed, notifying UI');
    notifyListeners();
  }

  /// Clear all favorites (for testing)
  Future<void> clearAllFavorites() async {
    await _favoritesService.clearAllFavorites();

    // Clear all data
    _favorites.clear();
    _favoriteReachIds.clear();
    _refreshingReachIds.clear();
    _sessionData.clear();
    _sessionReturnPeriods.clear();

    _clearError();
    notifyListeners();
  }

  /// Get just the reach IDs for notification system
  List<String> get favoriteReachIds =>
      _favorites.map((f) => f.reachId).toList();
}
