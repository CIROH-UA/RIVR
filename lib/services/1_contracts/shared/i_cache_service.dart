// lib/services/1_contracts/shared/i_cache_service.dart

/// Interface for cache operations (secure storage + shared preferences)
abstract class ICacheService {
  Future<void> initialize();
  bool get isReady;

  // Auth storage
  Future<void> storeAuthToken(String token);
  Future<String?> getAuthToken();
  Future<void> storeAuthData({
    required String userId,
    required String email,
    String? authToken,
  });
  Future<String?> getUserId();
  Future<String?> getUserEmail();
  Future<DateTime?> getLastLogin();
  Future<bool> hasAuthData();
  Future<void> clearAuthData();

  // Biometric preferences
  Future<void> cacheBiometricAvailable(bool available);
  bool? getCachedBiometricAvailable();
  Future<void> cacheBiometricEnabled(bool enabled);
  bool? getCachedBiometricEnabled();
  Future<void> cacheBiometricType(String type);
  String? getCachedBiometricType();
  Future<void> clearBiometricPreferences();

  // Recent searches
  Future<List<Map<String, dynamic>>> getRecentSearches();
  Future<void> storeRecentSearches(List<Map<String, dynamic>> searches);
  Future<List<Map<String, dynamic>>> addRecentSearch(
    Map<String, dynamic> searchData,
  );
  Future<void> clearRecentSearches();
  Future<int> getRecentSearchesCount();

  // General cache
  Future<void> storeString(String key, String value);
  String? getString(String key);
  Future<void> storeBool(String key, bool value);
  bool? getBool(String key);
  Future<void> storeInt(String key, int value);
  int? getInt(String key);
  Future<void> remove(String key);
  Future<void> clearAll();
  Future<void> clearEverything();
  Future<int> getCacheSize();
  Future<Set<String>> getAllKeys();
}
