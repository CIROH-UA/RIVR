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

  /// Set the per-river reminder frequency (ADR 0011 decision 19).
  ///
  /// Writes one entry into the `alertFrequencies` map on the user document.
  /// [wireValue] must be an [AlertFrequency.wireValue] — the server reads these
  /// strings directly, so an unrecognised one silently reverts that river to
  /// the default.
  Future<UserSettings?> updateRiverAlertFrequency(
    String userId,
    String reachId,
    String wireValue,
  );

  /// Set the same reminder frequency on every given river.
  ///
  /// One write rather than N: a per-river loop over twenty favourites is
  /// twenty round trips, and a partial failure would leave the list in a state
  /// the user never chose.
  Future<UserSettings?> updateAllRiverAlertFrequencies(
    String userId,
    List<String> reachIds,
    String wireValue,
  );
  void clearCache();
  Future<bool> userHasSettings(String userId);
  Future<void> syncFlowUnitPreference(String userId);

  /// Permanently delete the user's settings document and drop any cached
  /// copy. Caller is responsible for orchestrating the broader account-
  /// deletion flow (auth, FCM, biometric).
  Future<void> deleteUserSettings(String userId);
}
