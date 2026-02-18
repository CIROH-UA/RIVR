// lib/core/services/cache_service.dart

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'app_logger.dart';
import 'i_cache_service.dart';

/// Simple cache service for secure storage and preferences
class CacheService implements ICacheService {
  CacheService();

  // Secure storage for sensitive data
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // Shared preferences for non-sensitive caching
  SharedPreferences? _prefs;

  // Storage keys
  static const String _authTokenKey = 'auth_token';
  static const String _userIdKey = 'user_id';
  static const String _userEmailKey = 'user_email';
  static const String _lastLoginKey = 'last_login';

  // Biometric preference keys
  static const String _biometricEnabledKey = 'biometric_enabled';
  static const String _biometricAvailableKey = 'biometric_available';
  static const String _biometricTypeKey = 'biometric_type';

  // Recent searches keys
  static const String _recentSearchesKey = 'rivr_recent_searches';
  static const int _maxRecentSearches = 5;

  /// Initialize the cache service
  @override
  Future<void> initialize() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      AppLogger.info('CacheService', 'Initialized successfully');
    } catch (e) {
      AppLogger.error('CacheService', 'Error initializing: $e', e);
    }
  }

  // MARK: - Secure Authentication Storage

  /// Store authentication token securely
  @override
  Future<void> storeAuthToken(String token) async {
    try {
      await _secureStorage.write(key: _authTokenKey, value: token);
      AppLogger.info('CacheService', 'Auth token stored securely');
    } catch (e) {
      AppLogger.error('CacheService', 'Error storing auth token: $e', e);
      throw Exception('Failed to store authentication token');
    }
  }

  /// Get stored authentication token
  @override
  Future<String?> getAuthToken() async {
    try {
      final token = await _secureStorage.read(key: _authTokenKey);
      AppLogger.debug(
        'CacheService',
        'Auth token retrieved: ${token != null ? "exists" : "null"}',
      );
      return token;
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting auth token: $e', e);
      return null;
    }
  }

  /// Store user authentication data
  @override
  Future<void> storeAuthData({
    required String userId,
    required String email,
    String? authToken,
  }) async {
    try {
      await Future.wait([
        _secureStorage.write(key: _userIdKey, value: userId),
        _secureStorage.write(key: _userEmailKey, value: email),
        _secureStorage.write(
          key: _lastLoginKey,
          value: DateTime.now().toIso8601String(),
        ),
        if (authToken != null)
          _secureStorage.write(key: _authTokenKey, value: authToken),
      ]);
      AppLogger.info('CacheService', 'Auth data stored securely');
    } catch (e) {
      AppLogger.error('CacheService', 'Error storing auth data: $e', e);
      throw Exception('Failed to store authentication data');
    }
  }

  /// Get stored user ID
  @override
  Future<String?> getUserId() async {
    try {
      return await _secureStorage.read(key: _userIdKey);
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting user ID: $e', e);
      return null;
    }
  }

  /// Get stored user email
  @override
  Future<String?> getUserEmail() async {
    try {
      return await _secureStorage.read(key: _userEmailKey);
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting user email: $e', e);
      return null;
    }
  }

  /// Get last login timestamp
  @override
  Future<DateTime?> getLastLogin() async {
    try {
      final timestamp = await _secureStorage.read(key: _lastLoginKey);
      if (timestamp != null) {
        return DateTime.parse(timestamp);
      }
      return null;
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting last login: $e', e);
      return null;
    }
  }

  /// Check if user has stored auth data
  @override
  Future<bool> hasAuthData() async {
    try {
      final userId = await getUserId();
      return userId != null && userId.isNotEmpty;
    } catch (e) {
      AppLogger.error('CacheService', 'Error checking auth data: $e', e);
      return false;
    }
  }

  /// Clear all secure authentication data
  @override
  Future<void> clearAuthData() async {
    try {
      await Future.wait([
        _secureStorage.delete(key: _authTokenKey),
        _secureStorage.delete(key: _userIdKey),
        _secureStorage.delete(key: _userEmailKey),
        _secureStorage.delete(key: _lastLoginKey),
      ]);
      AppLogger.info('CacheService', 'Auth data cleared');
    } catch (e) {
      AppLogger.error('CacheService', 'Error clearing auth data: $e', e);
    }
  }

  // MARK: - Biometric Preferences Caching

  /// Cache biometric availability
  @override
  Future<void> cacheBiometricAvailable(bool available) async {
    try {
      await _ensurePrefsInitialized();
      await _prefs!.setBool(_biometricAvailableKey, available);
      AppLogger.debug('CacheService', 'Biometric availability cached: $available');
    } catch (e) {
      AppLogger.error('CacheService', 'Error caching biometric availability: $e', e);
    }
  }

  /// Get cached biometric availability
  @override
  bool? getCachedBiometricAvailable() {
    try {
      return _prefs?.getBool(_biometricAvailableKey);
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting cached biometric availability: $e', e);
      return null;
    }
  }

  /// Cache biometric enabled status
  @override
  Future<void> cacheBiometricEnabled(bool enabled) async {
    try {
      await _ensurePrefsInitialized();
      await _prefs!.setBool(_biometricEnabledKey, enabled);
      AppLogger.debug('CacheService', 'Biometric enabled status cached: $enabled');
    } catch (e) {
      AppLogger.error('CacheService', 'Error caching biometric enabled status: $e', e);
    }
  }

  /// Get cached biometric enabled status
  @override
  bool? getCachedBiometricEnabled() {
    try {
      return _prefs?.getBool(_biometricEnabledKey);
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting cached biometric enabled status: $e', e);
      return null;
    }
  }

  /// Cache biometric type (fingerprint, face, etc.)
  @override
  Future<void> cacheBiometricType(String type) async {
    try {
      await _ensurePrefsInitialized();
      await _prefs!.setString(_biometricTypeKey, type);
      AppLogger.debug('CacheService', 'Biometric type cached: $type');
    } catch (e) {
      AppLogger.error('CacheService', 'Error caching biometric type: $e', e);
    }
  }

  /// Get cached biometric type
  @override
  String? getCachedBiometricType() {
    try {
      return _prefs?.getString(_biometricTypeKey);
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting cached biometric type: $e', e);
      return null;
    }
  }

  /// Clear all biometric preferences
  @override
  Future<void> clearBiometricPreferences() async {
    try {
      await _ensurePrefsInitialized();
      await Future.wait([
        _prefs!.remove(_biometricAvailableKey),
        _prefs!.remove(_biometricEnabledKey),
        _prefs!.remove(_biometricTypeKey),
      ]);
      AppLogger.info('CacheService', 'Biometric preferences cleared');
    } catch (e) {
      AppLogger.error('CacheService', 'Error clearing biometric preferences: $e', e);
    }
  }

  // MARK: - Recent Search Caching

  /// Load recent searches from cache
  @override
  Future<List<Map<String, dynamic>>> getRecentSearches() async {
    try {
      await _ensurePrefsInitialized();
      final jsonString = _prefs!.getString(_recentSearchesKey);
      if (jsonString == null) {
        AppLogger.debug('CacheService', 'No recent searches found');
        return [];
      }

      final List<dynamic> jsonList = jsonDecode(jsonString);
      final searches = jsonList.cast<Map<String, dynamic>>();
      AppLogger.debug('CacheService', 'Loaded ${searches.length} recent searches');
      return searches;
    } catch (e) {
      AppLogger.error('CacheService', 'Error loading recent searches: $e', e);
      return [];
    }
  }

  /// Save recent searches to cache
  @override
  Future<void> storeRecentSearches(List<Map<String, dynamic>> searches) async {
    try {
      await _ensurePrefsInitialized();
      final jsonString = jsonEncode(searches);
      await _prefs!.setString(_recentSearchesKey, jsonString);
      AppLogger.debug('CacheService', 'Stored ${searches.length} recent searches');
    } catch (e) {
      AppLogger.error('CacheService', 'Error storing recent searches: $e', e);
    }
  }

  /// Add a new search to recent searches (maintains max limit and deduplicates)
  @override
  Future<List<Map<String, dynamic>>> addRecentSearch(
    Map<String, dynamic> searchData,
  ) async {
    try {
      // Get current searches
      final currentSearches = await getRecentSearches();

      // Remove if already exists (based on placeName)
      final placeName = searchData['placeName'] as String?;
      final updated = currentSearches
          .where((search) => search['placeName'] != placeName)
          .toList();

      // Add to beginning
      updated.insert(0, searchData);

      // Keep only max recent searches
      final trimmed = updated.take(_maxRecentSearches).toList();

      // Save to cache
      await storeRecentSearches(trimmed);

      AppLogger.debug('CacheService', 'Added recent search: $placeName');
      return trimmed;
    } catch (e) {
      AppLogger.error('CacheService', 'Error adding recent search: $e', e);
      return [];
    }
  }

  /// Clear all recent searches
  @override
  Future<void> clearRecentSearches() async {
    try {
      await _ensurePrefsInitialized();
      await _prefs!.remove(_recentSearchesKey);
      AppLogger.info('CacheService', 'Recent searches cleared');
    } catch (e) {
      AppLogger.error('CacheService', 'Error clearing recent searches: $e', e);
    }
  }

  /// Get number of recent searches
  @override
  Future<int> getRecentSearchesCount() async {
    final searches = await getRecentSearches();
    return searches.length;
  }

  // MARK: - General Cache Methods

  /// Store string value in preferences
  @override
  Future<void> storeString(String key, String value) async {
    try {
      await _ensurePrefsInitialized();
      await _prefs!.setString(key, value);
      AppLogger.debug('CacheService', 'String stored for key: $key');
    } catch (e) {
      AppLogger.error('CacheService', 'Error storing string for key $key: $e', e);
    }
  }

  /// Get string value from preferences
  @override
  String? getString(String key) {
    try {
      return _prefs?.getString(key);
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting string for key $key: $e', e);
      return null;
    }
  }

  /// Store boolean value in preferences
  @override
  Future<void> storeBool(String key, bool value) async {
    try {
      await _ensurePrefsInitialized();
      await _prefs!.setBool(key, value);
      AppLogger.debug('CacheService', 'Bool stored for key: $key');
    } catch (e) {
      AppLogger.error('CacheService', 'Error storing bool for key $key: $e', e);
    }
  }

  /// Get boolean value from preferences
  @override
  bool? getBool(String key) {
    try {
      return _prefs?.getBool(key);
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting bool for key $key: $e', e);
      return null;
    }
  }

  /// Store integer value in preferences
  @override
  Future<void> storeInt(String key, int value) async {
    try {
      await _ensurePrefsInitialized();
      await _prefs!.setInt(key, value);
      AppLogger.debug('CacheService', 'Int stored for key: $key');
    } catch (e) {
      AppLogger.error('CacheService', 'Error storing int for key $key: $e', e);
    }
  }

  /// Get integer value from preferences
  @override
  int? getInt(String key) {
    try {
      return _prefs?.getInt(key);
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting int for key $key: $e', e);
      return null;
    }
  }

  /// Remove value from preferences
  @override
  Future<void> remove(String key) async {
    try {
      await _ensurePrefsInitialized();
      await _prefs!.remove(key);
      AppLogger.debug('CacheService', 'Value removed for key: $key');
    } catch (e) {
      AppLogger.error('CacheService', 'Error removing value for key $key: $e', e);
    }
  }

  /// Clear all non-secure cache data
  @override
  Future<void> clearAll() async {
    try {
      await _ensurePrefsInitialized();
      await _prefs!.clear();
      AppLogger.info('CacheService', 'All preferences cleared');
    } catch (e) {
      AppLogger.error('CacheService', 'Error clearing all preferences: $e', e);
    }
  }

  /// Clear everything (secure and non-secure)
  @override
  Future<void> clearEverything() async {
    await Future.wait([clearAuthData(), clearAll()]);
    AppLogger.info('CacheService', 'Everything cleared');
  }

  // MARK: - Helper Methods

  /// Ensure SharedPreferences is initialized
  Future<void> _ensurePrefsInitialized() async {
    if (_prefs == null) {
      await initialize();
    }
  }

  /// Check if cache service is ready to use
  @override
  bool get isReady => _prefs != null;

  /// Get cache size estimation (number of stored keys)
  @override
  Future<int> getCacheSize() async {
    try {
      await _ensurePrefsInitialized();
      return _prefs!.getKeys().length;
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting cache size: $e', e);
      return 0;
    }
  }

  /// Debug method to list all cached keys
  @override
  Future<Set<String>> getAllKeys() async {
    try {
      await _ensurePrefsInitialized();
      return _prefs!.getKeys();
    } catch (e) {
      AppLogger.error('CacheService', 'Error getting all keys: $e', e);
      return <String>{};
    }
  }
}
