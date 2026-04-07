// lib/services/1_contracts/shared/i_user_settings_service.dart

import 'package:rivr/models/1_domain/shared/user_settings.dart';

/// Interface for managing UserSettings with Firestore
abstract class IUserSettingsService {
  Future<UserSettings?> getUserSettings(String userId);
  Future<void> saveUserSettings(UserSettings settings);
  Future<void> updateUserSettings(String userId, Map<String, dynamic> updates);
  Future<UserSettings?> addCustomBackgroundImage(
    String userId,
    String imagePath,
  );
  Future<UserSettings?> removeCustomBackgroundImage(
    String userId,
    String imagePath,
  );
  Future<List<String>> getUserCustomBackgrounds(String userId);
  Future<UserSettings?> validateCustomBackgrounds(String userId);
  Future<UserSettings?> clearAllCustomBackgrounds(String userId);
  Future<UserSettings> createDefaultSettings({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
  });
  Future<UserSettings?> syncAfterLogin(String userId);
  Future<UserSettings?> addFavoriteReach(String userId, String reachId);
  Future<UserSettings?> removeFavoriteReach(String userId, String reachId);
  Future<UserSettings?> updateFlowUnit(String userId, FlowUnit flowUnit);
  Future<UserSettings?> updateNotifications(
    String userId,
    bool enableNotifications,
  );
  Future<UserSettings?> updateNotificationFrequency(
    String userId,
    int frequency,
  );
  void clearCache();
  Future<bool> userHasSettings(String userId);
  Future<void> syncFlowUnitPreference(String userId);
}
