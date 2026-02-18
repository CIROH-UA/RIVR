// lib/features/auth/services/user_settings_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/models/user_settings.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/error_service.dart';
import '../../../core/services/i_flow_unit_preference_service.dart';
import '../../../core/services/i_background_image_service.dart';
import 'i_user_settings_service.dart';

/// Simple service for managing UserSettings with Firestore
class UserSettingsService implements IUserSettingsService {
  final FirebaseFirestore _firestore;
  final IFlowUnitPreferenceService _flowUnitService;
  final IBackgroundImageService _backgroundImageService;

  UserSettingsService({
    FirebaseFirestore? firestore,
    required IFlowUnitPreferenceService unitService,
    required IBackgroundImageService imageService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _flowUnitService = unitService,
        _backgroundImageService = imageService;

  // Simple in-memory cache
  UserSettings? _cachedSettings;
  String? _cachedUserId;

  /// Get UserSettings for a user
  @override
  Future<UserSettings?> getUserSettings(String userId) async {
    try {
      AppLogger.debug('UserSettingsService', 'Getting settings for user: $userId');

      // Return cached settings if available for this user
      if (_cachedSettings != null && _cachedUserId == userId) {
        AppLogger.debug('UserSettingsService', 'Returning cached settings');
        return _cachedSettings;
      }

      // Fetch from Firestore
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .get()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Settings fetch timed out'),
          );

      if (!doc.exists) {
        AppLogger.debug('UserSettingsService', 'No settings found for user: $userId');
        return null;
      }

      final settings = UserSettings.fromJson(doc.data()!);

      // Cache the settings
      _cachedSettings = settings;
      _cachedUserId = userId;

      AppLogger.info('UserSettingsService', 'Settings loaded successfully');
      return settings;
    } on FirebaseException catch (e) {
      AppLogger.error('UserSettingsService', 'Firestore error: ${e.code} - ${e.message}', e);
      throw Exception(ErrorService.mapFirestoreError(e));
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error getting user settings: $e', e);
      throw Exception('Failed to load user settings: ${e.toString()}');
    }
  }

  /// Save UserSettings to Firestore
  @override
  Future<void> saveUserSettings(UserSettings settings) async {
    try {
      AppLogger.debug(
        'UserSettingsService',
        'Saving settings for user: ${settings.userId}',
      );

      await _firestore
          .collection('users')
          .doc(settings.userId)
          .set(settings.toJson())
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Settings save timed out'),
          );

      // Update cache
      _cachedSettings = settings;
      _cachedUserId = settings.userId;

      AppLogger.info('UserSettingsService', 'Settings saved successfully');
    } on FirebaseException catch (e) {
      AppLogger.error(
        'UserSettingsService',
        'Firestore save error: ${e.code} - ${e.message}',
        e,
      );
      throw Exception(ErrorService.mapFirestoreError(e));
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error saving user settings: $e', e);
      throw Exception('Failed to save user settings: ${e.toString()}');
    }
  }

  /// Update specific settings fields
  @override
  Future<void> updateUserSettings(
    String userId,
    Map<String, dynamic> updates,
  ) async {
    try {
      AppLogger.debug('UserSettingsService', 'Updating settings for user: $userId');

      // Add updatedAt timestamp
      final updateData = {
        ...updates,
        'updatedAt': DateTime.now().toIso8601String(),
      };

      await _firestore
          .collection('users')
          .doc(userId)
          .update(updateData)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Settings update timed out'),
          );

      // Clear cache to force refresh on next get
      if (_cachedUserId == userId) {
        _cachedSettings = null;
        _cachedUserId = null;
      }

      AppLogger.info('UserSettingsService', 'Settings updated successfully');
    } on FirebaseException catch (e) {
      AppLogger.error(
        'UserSettingsService',
        'Firestore update error: ${e.code} - ${e.message}',
        e,
      );
      throw Exception(ErrorService.mapFirestoreError(e));
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error updating user settings: $e', e);
      throw Exception('Failed to update user settings: ${e.toString()}');
    }
  }

  // NEW: Custom Background Management Methods

  /// Add custom background image to user's collection
  @override
  Future<UserSettings?> addCustomBackgroundImage(
    String userId,
    String imagePath,
  ) async {
    try {
      AppLogger.debug(
        'UserSettingsService',
        'Adding custom background for user: $userId',
      );

      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      // Add to user's collection
      final updatedSettings = settings.addCustomBackground(imagePath);
      await saveUserSettings(updatedSettings);

      AppLogger.info('UserSettingsService', 'Custom background added successfully');
      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error adding custom background: $e', e);
      throw Exception('Failed to add custom background: ${e.toString()}');
    }
  }

  /// Remove custom background image from user's collection
  @override
  Future<UserSettings?> removeCustomBackgroundImage(
    String userId,
    String imagePath,
  ) async {
    try {
      AppLogger.debug(
        'UserSettingsService',
        'Removing custom background for user: $userId',
      );

      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      // Remove from user's collection
      final updatedSettings = settings.removeCustomBackground(imagePath);
      await saveUserSettings(updatedSettings);

      // Delete the actual image file
      await _backgroundImageService.deleteCustomBackground(imagePath);

      AppLogger.info('UserSettingsService', 'Custom background removed successfully');
      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error removing custom background: $e', e);
      throw Exception('Failed to remove custom background: ${e.toString()}');
    }
  }

  /// Get user's custom background images
  @override
  Future<List<String>> getUserCustomBackgrounds(String userId) async {
    try {
      final settings = await getUserSettings(userId);
      return settings?.customBackgroundImagePaths ?? [];
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error getting custom backgrounds: $e', e);
      return [];
    }
  }

  /// Validate custom background images and remove broken references
  @override
  Future<UserSettings?> validateCustomBackgrounds(String userId) async {
    try {
      AppLogger.debug(
        'UserSettingsService',
        'Validating custom backgrounds for user: $userId',
      );

      final settings = await getUserSettings(userId);
      if (settings == null || !settings.hasCustomBackgrounds) {
        return settings;
      }

      final validPaths = <String>[];

      // Check each custom background image
      for (final imagePath in settings.customBackgroundImagePaths) {
        final exists = await _backgroundImageService.imageExists(imagePath);
        if (exists) {
          validPaths.add(imagePath);
        } else {
          AppLogger.warning(
            'UserSettingsService',
            'Removing invalid background: $imagePath',
          );
        }
      }

      // Update settings if any paths were removed
      if (validPaths.length != settings.customBackgroundImagePaths.length) {
        final updatedSettings = settings.copyWith(
          customBackgroundImagePaths: validPaths,
        );
        await saveUserSettings(updatedSettings);

        AppLogger.info(
          'UserSettingsService',
          'Cleaned up ${settings.customBackgroundImagePaths.length - validPaths.length} invalid backgrounds',
        );
        return updatedSettings;
      }

      AppLogger.info('UserSettingsService', 'All custom backgrounds are valid');
      return settings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error validating custom backgrounds: $e', e);
      return null;
    }
  }

  /// Clear all custom background images for user
  @override
  Future<UserSettings?> clearAllCustomBackgrounds(String userId) async {
    try {
      AppLogger.debug(
        'UserSettingsService',
        'Clearing all custom backgrounds for user: $userId',
      );

      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      // Delete all image files
      for (final imagePath in settings.customBackgroundImagePaths) {
        await _backgroundImageService.deleteCustomBackground(imagePath);
      }

      // Update settings
      final updatedSettings = settings.clearAllCustomBackgrounds();
      await saveUserSettings(updatedSettings);

      AppLogger.info('UserSettingsService', 'All custom backgrounds cleared');
      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error clearing custom backgrounds: $e', e);
      throw Exception('Failed to clear custom backgrounds: ${e.toString()}');
    }
  }

  // END: Custom Background Management Methods

  /// Create default settings for a new user
  @override
  Future<UserSettings> createDefaultSettings({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
  }) async {
    try {
      AppLogger.debug(
        'UserSettingsService',
        'Creating default settings for user: $userId',
      );

      final now = DateTime.now();
      final settings = UserSettings(
        userId: userId,
        email: email,
        firstName: firstName,
        lastName: lastName,
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twelveHour,
        enableNotifications: true,
        enableDarkMode: false,
        favoriteReachIds: [],
        customBackgroundImagePaths: [], // NEW: Initialize empty list
        lastLoginDate: now,
        createdAt: now,
        updatedAt: now,
      );

      await saveUserSettings(settings);
      AppLogger.info('UserSettingsService', 'Default settings created successfully');

      return settings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error creating default settings: $e', e);
      throw Exception('Failed to create user settings: ${e.toString()}');
    }
  }

  /// Sync settings after login (updates lastLoginDate)
  @override
  Future<UserSettings?> syncAfterLogin(String userId) async {
    try {
      AppLogger.debug(
        'UserSettingsService',
        'Syncing settings after login for user: $userId',
      );

      // Get current settings
      final settings = await getUserSettings(userId);
      if (settings == null) {
        AppLogger.warning('UserSettingsService', 'No settings found during sync');
        return null;
      }

      // Validate custom backgrounds (remove if files missing)
      final validatedSettings = await validateCustomBackgrounds(userId);

      // Sync flow unit preference to FlowUnitPreferenceService
      _syncFlowUnitToService(
        validatedSettings?.preferredFlowUnit ?? settings.preferredFlowUnit,
      );

      // Update last login date
      final updatedSettings = (validatedSettings ?? settings).copyWith(
        lastLoginDate: DateTime.now(),
      );
      await saveUserSettings(updatedSettings);

      AppLogger.info('UserSettingsService', 'Settings synced successfully');
      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error syncing settings: $e', e);
      // Don't throw here - login can still succeed even if sync fails
      return null;
    }
  }

  /// Add favorite reach
  @override
  Future<UserSettings?> addFavoriteReach(String userId, String reachId) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      final updatedSettings = settings.addFavorite(reachId);
      await saveUserSettings(updatedSettings);

      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error adding favorite: $e', e);
      throw Exception('Failed to add favorite: ${e.toString()}');
    }
  }

  /// Remove favorite reach
  @override
  Future<UserSettings?> removeFavoriteReach(
    String userId,
    String reachId,
  ) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      final updatedSettings = settings.removeFavorite(reachId);
      await saveUserSettings(updatedSettings);

      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error removing favorite: $e', e);
      throw Exception('Failed to remove favorite: ${e.toString()}');
    }
  }

  /// Update theme preference
  @override
  Future<UserSettings?> updateTheme(String userId, bool enableDarkMode) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      final updatedSettings = settings.copyWith(enableDarkMode: enableDarkMode);
      await saveUserSettings(updatedSettings);

      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error updating theme: $e', e);
      throw Exception('Failed to update theme: ${e.toString()}');
    }
  }

  /// Update flow unit preference
  @override
  Future<UserSettings?> updateFlowUnit(String userId, FlowUnit flowUnit) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      final updatedSettings = settings.copyWith(preferredFlowUnit: flowUnit);
      await saveUserSettings(updatedSettings);

      // Sync the change to FlowUnitPreferenceService immediately
      _syncFlowUnitToService(flowUnit);

      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error updating flow unit: $e', e);
      throw Exception('Failed to update flow unit: ${e.toString()}');
    }
  }

  /// Update notification preference
  @override
  Future<UserSettings?> updateNotifications(
    String userId,
    bool enableNotifications,
  ) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      final updatedSettings = settings.copyWith(
        enableNotifications: enableNotifications,
      );
      await saveUserSettings(updatedSettings);

      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error updating notifications: $e', e);
      throw Exception('Failed to update notifications: ${e.toString()}');
    }
  }

  /// Update notification frequency preference
  @override
  Future<UserSettings?> updateNotificationFrequency(
    String userId,
    int frequency,
  ) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      final updatedSettings = settings.copyWith(
        notificationFrequency: frequency,
      );
      await saveUserSettings(updatedSettings);

      return updatedSettings;
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error updating notification frequency: $e', e);
      throw Exception(
        'Failed to update notification frequency: ${e.toString()}',
      );
    }
  }

  /// Clear cached settings (call on sign out)
  @override
  void clearCache() {
    AppLogger.debug('UserSettingsService', 'Clearing cache');
    _cachedSettings = null;
    _cachedUserId = null;

    // Reset flow unit to default when user signs out
    _flowUnitService.resetToDefault();
  }

  /// Get cached settings (if available)
  UserSettings? get cachedSettings => _cachedSettings;

  /// Check if user has settings
  @override
  Future<bool> userHasSettings(String userId) async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .get()
          .timeout(const Duration(seconds: 5));

      return doc.exists;
    } catch (e) {
      AppLogger.error(
        'UserSettingsService',
        'Error checking user settings existence: $e',
        e,
      );
      return false;
    }
  }

  /// Sync flow unit preference from UserSettings to FlowUnitPreferenceService
  void _syncFlowUnitToService(FlowUnit flowUnit) {
    final unitString = flowUnit == FlowUnit.cms ? 'CMS' : 'CFS';
    _flowUnitService.setFlowUnit(unitString);
    AppLogger.debug('UserSettingsService', 'Synced flow unit preference: $unitString');
  }

  /// Public method to manually sync flow unit preference
  @override
  Future<void> syncFlowUnitPreference(String userId) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings?.preferredFlowUnit != null) {
        _syncFlowUnitToService(settings!.preferredFlowUnit);
      }
    } catch (e) {
      AppLogger.error('UserSettingsService', 'Error syncing flow unit preference: $e', e);
      // Don't throw - this is not critical
    }
  }
}
