// lib/features/auth/services/user_settings_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/models/user_settings.dart';
import '../../../core/services/error_service.dart';
import '../../../core/services/flow_unit_preference_service.dart';
import '../../../core/services/background_image_service.dart'; // NEW: For file management

/// Simple service for managing UserSettings with Firestore
class UserSettingsService {
  static final UserSettingsService _instance = UserSettingsService._internal();
  factory UserSettingsService() => _instance;
  UserSettingsService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FlowUnitPreferenceService _flowUnitService =
      FlowUnitPreferenceService();
  final BackgroundImageService _backgroundImageService =
      BackgroundImageService(); // NEW: Background service instance

  // Simple in-memory cache
  UserSettings? _cachedSettings;
  String? _cachedUserId;

  /// Get UserSettings for a user
  Future<UserSettings?> getUserSettings(String userId) async {
    try {
      print('USER_SETTINGS_SERVICE: Getting settings for user: $userId');

      // Return cached settings if available for this user
      if (_cachedSettings != null && _cachedUserId == userId) {
        print('USER_SETTINGS_SERVICE: Returning cached settings');
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
        print('USER_SETTINGS_SERVICE: No settings found for user: $userId');
        return null;
      }

      final settings = UserSettings.fromJson(doc.data()!);

      // Cache the settings
      _cachedSettings = settings;
      _cachedUserId = userId;

      print('USER_SETTINGS_SERVICE: Settings loaded successfully');
      return settings;
    } on FirebaseException catch (e) {
      print('USER_SETTINGS_SERVICE: Firestore error: ${e.code} - ${e.message}');
      throw Exception(ErrorService.mapFirestoreError(e));
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error getting user settings: $e');
      throw Exception('Failed to load user settings: ${e.toString()}');
    }
  }

  /// Save UserSettings to Firestore
  Future<void> saveUserSettings(UserSettings settings) async {
    try {
      print(
        'USER_SETTINGS_SERVICE: Saving settings for user: ${settings.userId}',
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

      print('USER_SETTINGS_SERVICE: Settings saved successfully');
    } on FirebaseException catch (e) {
      print(
        'USER_SETTINGS_SERVICE: Firestore save error: ${e.code} - ${e.message}',
      );
      throw Exception(ErrorService.mapFirestoreError(e));
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error saving user settings: $e');
      throw Exception('Failed to save user settings: ${e.toString()}');
    }
  }

  /// Update specific settings fields
  Future<void> updateUserSettings(
    String userId,
    Map<String, dynamic> updates,
  ) async {
    try {
      print('USER_SETTINGS_SERVICE: Updating settings for user: $userId');

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

      print('USER_SETTINGS_SERVICE: Settings updated successfully');
    } on FirebaseException catch (e) {
      print(
        'USER_SETTINGS_SERVICE: Firestore update error: ${e.code} - ${e.message}',
      );
      throw Exception(ErrorService.mapFirestoreError(e));
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error updating user settings: $e');
      throw Exception('Failed to update user settings: ${e.toString()}');
    }
  }

  // NEW: Custom Background Management Methods

  /// Add custom background image to user's collection
  Future<UserSettings?> addCustomBackgroundImage(
    String userId,
    String imagePath,
  ) async {
    try {
      print(
        'USER_SETTINGS_SERVICE: Adding custom background for user: $userId',
      );

      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      // Add to user's collection
      final updatedSettings = settings.addCustomBackground(imagePath);
      await saveUserSettings(updatedSettings);

      print('USER_SETTINGS_SERVICE: Custom background added successfully');
      return updatedSettings;
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error adding custom background: $e');
      throw Exception('Failed to add custom background: ${e.toString()}');
    }
  }

  /// Remove custom background image from user's collection
  Future<UserSettings?> removeCustomBackgroundImage(
    String userId,
    String imagePath,
  ) async {
    try {
      print(
        'USER_SETTINGS_SERVICE: Removing custom background for user: $userId',
      );

      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      // Remove from user's collection
      final updatedSettings = settings.removeCustomBackground(imagePath);
      await saveUserSettings(updatedSettings);

      // Delete the actual image file
      await _backgroundImageService.deleteCustomBackground(imagePath);

      print('USER_SETTINGS_SERVICE: Custom background removed successfully');
      return updatedSettings;
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error removing custom background: $e');
      throw Exception('Failed to remove custom background: ${e.toString()}');
    }
  }

  /// Get user's custom background images
  Future<List<String>> getUserCustomBackgrounds(String userId) async {
    try {
      final settings = await getUserSettings(userId);
      return settings?.customBackgroundImagePaths ?? [];
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error getting custom backgrounds: $e');
      return [];
    }
  }

  /// Validate custom background images and remove broken references
  Future<UserSettings?> validateCustomBackgrounds(String userId) async {
    try {
      print(
        'USER_SETTINGS_SERVICE: Validating custom backgrounds for user: $userId',
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
          print(
            'USER_SETTINGS_SERVICE: Removing invalid background: $imagePath',
          );
        }
      }

      // Update settings if any paths were removed
      if (validPaths.length != settings.customBackgroundImagePaths.length) {
        final updatedSettings = settings.copyWith(
          customBackgroundImagePaths: validPaths,
        );
        await saveUserSettings(updatedSettings);

        print(
          'USER_SETTINGS_SERVICE: Cleaned up ${settings.customBackgroundImagePaths.length - validPaths.length} invalid backgrounds',
        );
        return updatedSettings;
      }

      print('USER_SETTINGS_SERVICE: All custom backgrounds are valid');
      return settings;
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error validating custom backgrounds: $e');
      return null;
    }
  }

  /// Clear all custom background images for user
  Future<UserSettings?> clearAllCustomBackgrounds(String userId) async {
    try {
      print(
        'USER_SETTINGS_SERVICE: Clearing all custom backgrounds for user: $userId',
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

      print('USER_SETTINGS_SERVICE: All custom backgrounds cleared');
      return updatedSettings;
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error clearing custom backgrounds: $e');
      throw Exception('Failed to clear custom backgrounds: ${e.toString()}');
    }
  }

  // END: Custom Background Management Methods

  /// Create default settings for a new user
  Future<UserSettings> createDefaultSettings({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
  }) async {
    try {
      print(
        'USER_SETTINGS_SERVICE: Creating default settings for user: $userId',
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
      print('USER_SETTINGS_SERVICE: Default settings created successfully');

      return settings;
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error creating default settings: $e');
      throw Exception('Failed to create user settings: ${e.toString()}');
    }
  }

  /// Sync settings after login (updates lastLoginDate)
  Future<UserSettings?> syncAfterLogin(String userId) async {
    try {
      print(
        'USER_SETTINGS_SERVICE: Syncing settings after login for user: $userId',
      );

      // Get current settings
      final settings = await getUserSettings(userId);
      if (settings == null) {
        print('USER_SETTINGS_SERVICE: No settings found during sync');
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

      print('USER_SETTINGS_SERVICE: Settings synced successfully');
      return updatedSettings;
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error syncing settings: $e');
      // Don't throw here - login can still succeed even if sync fails
      return null;
    }
  }

  /// Add favorite reach
  Future<UserSettings?> addFavoriteReach(String userId, String reachId) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      final updatedSettings = settings.addFavorite(reachId);
      await saveUserSettings(updatedSettings);

      return updatedSettings;
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error adding favorite: $e');
      throw Exception('Failed to add favorite: ${e.toString()}');
    }
  }

  /// Remove favorite reach
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
      print('USER_SETTINGS_SERVICE: Error removing favorite: $e');
      throw Exception('Failed to remove favorite: ${e.toString()}');
    }
  }

  /// Update theme preference
  Future<UserSettings?> updateTheme(String userId, bool enableDarkMode) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings == null) return null;

      final updatedSettings = settings.copyWith(enableDarkMode: enableDarkMode);
      await saveUserSettings(updatedSettings);

      return updatedSettings;
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error updating theme: $e');
      throw Exception('Failed to update theme: ${e.toString()}');
    }
  }

  /// Update flow unit preference
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
      print('USER_SETTINGS_SERVICE: Error updating flow unit: $e');
      throw Exception('Failed to update flow unit: ${e.toString()}');
    }
  }

  /// Update notification preference
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
      print('USER_SETTINGS_SERVICE: Error updating notifications: $e');
      throw Exception('Failed to update notifications: ${e.toString()}');
    }
  }

  /// Clear cached settings (call on sign out)
  void clearCache() {
    print('USER_SETTINGS_SERVICE: Clearing cache');
    _cachedSettings = null;
    _cachedUserId = null;

    // Reset flow unit to default when user signs out
    _flowUnitService.resetToDefault();
  }

  /// Get cached settings (if available)
  UserSettings? get cachedSettings => _cachedSettings;

  /// Check if user has settings
  Future<bool> userHasSettings(String userId) async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .get()
          .timeout(const Duration(seconds: 5));

      return doc.exists;
    } catch (e) {
      print(
        'USER_SETTINGS_SERVICE: Error checking user settings existence: $e',
      );
      return false;
    }
  }

  /// Sync flow unit preference from UserSettings to FlowUnitPreferenceService
  void _syncFlowUnitToService(FlowUnit flowUnit) {
    final unitString = flowUnit == FlowUnit.cms ? 'CMS' : 'CFS';
    _flowUnitService.setFlowUnit(unitString);
    print('USER_SETTINGS_SERVICE: Synced flow unit preference: $unitString');
  }

  /// Public method to manually sync flow unit preference
  Future<void> syncFlowUnitPreference(String userId) async {
    try {
      final settings = await getUserSettings(userId);
      if (settings?.preferredFlowUnit != null) {
        _syncFlowUnitToService(settings!.preferredFlowUnit);
      }
    } catch (e) {
      print('USER_SETTINGS_SERVICE: Error syncing flow unit preference: $e');
      // Don't throw - this is not critical
    }
  }
}
