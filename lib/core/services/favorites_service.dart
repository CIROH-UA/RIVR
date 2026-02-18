// lib/core/services/favorites_service.dart

import '../models/favorite_river.dart';
import '../../features/auth/services/i_user_settings_service.dart';
import 'app_logger.dart';
import 'i_auth_service.dart';
import 'i_favorites_service.dart';

/// Simple service for managing user's favorite rivers
/// Uses Firestore via UserSettings.favoriteReachIds - no local storage
class FavoritesService implements IFavoritesService {
  final IUserSettingsService _userSettingsService;
  final IAuthService _authService;

  FavoritesService({
    required IUserSettingsService settingsService,
    required IAuthService authService,
  })  : _userSettingsService = settingsService,
        _authService = authService;

  /// Get current user ID or return null if not signed in
  String? get _currentUserIdOrNull => _authService.currentUser?.uid;

  /// Load all favorites from Firestore
  @override
  Future<List<FavoriteRiver>> loadFavorites() async {
    try {
      AppLogger.debug('FavoritesService', 'Loading favorites from Firestore');

      final userId = _currentUserIdOrNull;
      if (userId == null) {
        AppLogger.debug('FavoritesService', 'No user signed in - returning empty list');
        return [];
      }

      final userSettings = await _userSettingsService.getUserSettings(userId);
      if (userSettings == null) {
        AppLogger.debug('FavoritesService', 'No user settings found - returning empty list');
        return [];
      }

      // Convert simple reach IDs to FavoriteRiver objects
      final favorites = <FavoriteRiver>[];
      for (int i = 0; i < userSettings.favoriteReachIds.length; i++) {
        final reachId = userSettings.favoriteReachIds[i];
        favorites.add(
          FavoriteRiver(
            reachId: reachId,
            displayOrder: i, // Use array index as display order
          ),
        );
      }

      AppLogger.info('FavoritesService', 'Loaded ${favorites.length} favorites from cloud');
      return favorites;
    } catch (e) {
      AppLogger.error('FavoritesService', 'Error loading favorites: $e', e);
      return [];
    }
  }

  /// Save all favorites to Firestore
  @override
  Future<bool> saveFavorites(List<FavoriteRiver> favorites) async {
    try {
      final userId = _currentUserIdOrNull;
      if (userId == null) {
        AppLogger.debug('FavoritesService', 'No user signed in - cannot save');
        return false;
      }

      AppLogger.debug('FavoritesService', 'Saving ${favorites.length} favorites to cloud');

      // Sort by display order first
      final sortedFavorites = List<FavoriteRiver>.from(favorites);
      sortedFavorites.sort((a, b) => a.displayOrder.compareTo(b.displayOrder));

      // Extract just the reach IDs in order
      final reachIds = sortedFavorites.map((f) => f.reachId).toList();

      // Update user settings
      await _userSettingsService.updateUserSettings(userId, {
        'favoriteReachIds': reachIds,
      });

      AppLogger.info('FavoritesService', 'Favorites saved to cloud successfully');
      return true;
    } catch (e) {
      AppLogger.error('FavoritesService', 'Error saving favorites: $e', e);
      return false;
    }
  }

  /// Add a new favorite river
  @override
  Future<bool> addFavorite(
    String reachId, {
    String? customName,
    double? latitude,
    double? longitude,
  }) async {
    try {
      final userId = _currentUserIdOrNull;
      if (userId == null) {
        AppLogger.debug('FavoritesService', 'No user signed in - cannot add favorite');
        return false;
      }

      AppLogger.debug('FavoritesService', 'Adding favorite: $reachId');

      final userSettings = await _userSettingsService.getUserSettings(userId);
      if (userSettings == null) {
        AppLogger.error('FavoritesService', 'No user settings found');
        return false;
      }

      // Check if already exists
      if (userSettings.favoriteReachIds.contains(reachId)) {
        AppLogger.warning('FavoritesService', 'Reach $reachId already in favorites');
        return false;
      }

      // Add to the end of the list
      final updatedReachIds = [...userSettings.favoriteReachIds, reachId];

      // Update user settings
      await _userSettingsService.updateUserSettings(userId, {
        'favoriteReachIds': updatedReachIds,
      });

      AppLogger.info('FavoritesService', 'Added favorite: $reachId');
      return true;
    } catch (e) {
      AppLogger.error('FavoritesService', 'Error adding favorite: $e', e);
      return false;
    }
  }

  /// Remove a favorite river
  @override
  Future<bool> removeFavorite(String reachId) async {
    try {
      final userId = _currentUserIdOrNull;
      if (userId == null) {
        AppLogger.debug('FavoritesService', 'No user signed in - cannot remove favorite');
        return false;
      }

      AppLogger.debug('FavoritesService', 'Removing favorite: $reachId');

      final userSettings = await _userSettingsService.getUserSettings(userId);
      if (userSettings == null) {
        AppLogger.error('FavoritesService', 'No user settings found');
        return false;
      }

      // Check if exists
      if (!userSettings.favoriteReachIds.contains(reachId)) {
        AppLogger.warning('FavoritesService', 'Reach $reachId not found in favorites');
        return false;
      }

      // Remove from list
      final updatedReachIds = userSettings.favoriteReachIds
          .where((id) => id != reachId)
          .toList();

      // Update user settings
      await _userSettingsService.updateUserSettings(userId, {
        'favoriteReachIds': updatedReachIds,
      });

      AppLogger.info('FavoritesService', 'Removed favorite: $reachId');
      return true;
    } catch (e) {
      AppLogger.error('FavoritesService', 'Error removing favorite: $e', e);
      return false;
    }
  }

  /// Check if a reach is favorited
  @override
  Future<bool> isFavorite(String reachId) async {
    try {
      final userId = _currentUserIdOrNull;
      if (userId == null) return false;

      final userSettings = await _userSettingsService.getUserSettings(userId);
      if (userSettings == null) return false;

      return userSettings.favoriteReachIds.contains(reachId);
    } catch (e) {
      AppLogger.error('FavoritesService', 'Error checking favorite status: $e', e);
      return false;
    }
  }

  /// Reorder favorites (for drag-and-drop)
  @override
  Future<bool> reorderFavorites(List<FavoriteRiver> reorderedFavorites) async {
    try {
      final userId = _currentUserIdOrNull;
      if (userId == null) {
        AppLogger.debug('FavoritesService', 'No user signed in - cannot reorder');
        return false;
      }

      AppLogger.debug('FavoritesService', 'Reordering ${reorderedFavorites.length} favorites');

      // Extract reach IDs in the new order
      final reorderedReachIds = reorderedFavorites
          .map((f) => f.reachId)
          .toList();

      // Update user settings with new order
      await _userSettingsService.updateUserSettings(userId, {
        'favoriteReachIds': reorderedReachIds,
      });

      AppLogger.info('FavoritesService', 'Favorites reordered successfully');
      return true;
    } catch (e) {
      AppLogger.error('FavoritesService', 'Error reordering favorites: $e', e);
      return false;
    }
  }

  /// Update a favorite's properties
  @override
  Future<bool> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
    double? lastKnownFlow,
    DateTime? lastUpdated,
    double? latitude,
    double? longitude,
  }) async {
    try {
      final userId = _currentUserIdOrNull;
      if (userId == null) return false;

      AppLogger.debug('FavoritesService', 'Update favorite called for: $reachId');

      // Check if favorite exists
      final isFav = await isFavorite(reachId);
      if (!isFav) {
        AppLogger.warning('FavoritesService', 'Reach $reachId not found for update');
        return false;
      }

      AppLogger.warning('FavoritesService', 'Note: Extra properties not persisted in simplified cloud storage');
      return true;
    } catch (e) {
      AppLogger.error('FavoritesService', 'Error updating favorite: $e', e);
      return false;
    }
  }

  /// Get count of favorites
  @override
  Future<int> getFavoritesCount() async {
    try {
      final userId = _currentUserIdOrNull;
      if (userId == null) return 0;

      final userSettings = await _userSettingsService.getUserSettings(userId);
      if (userSettings == null) return 0;

      return userSettings.favoriteReachIds.length;
    } catch (e) {
      AppLogger.error('FavoritesService', 'Error getting favorites count: $e', e);
      return 0;
    }
  }

  /// Clear all favorites
  @override
  Future<bool> clearAllFavorites() async {
    try {
      final userId = _currentUserIdOrNull;
      if (userId == null) {
        AppLogger.debug('FavoritesService', 'No user signed in - cannot clear');
        return false;
      }

      AppLogger.debug('FavoritesService', 'Clearing all favorites');

      // Update user settings with empty list
      await _userSettingsService.updateUserSettings(userId, {
        'favoriteReachIds': <String>[],
      });

      AppLogger.info('FavoritesService', 'All favorites cleared');
      return true;
    } catch (e) {
      AppLogger.error('FavoritesService', 'Error clearing favorites: $e', e);
      return false;
    }
  }
}
