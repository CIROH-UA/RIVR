// integration_test/helpers/mock_services.dart
//
// In-memory mock implementations of all service interfaces for integration tests.
// These are hand-written fakes (not mockito) for full control over behavior.

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart' show MockUser;
import 'package:rivr/core/models/reach_data.dart';
import 'package:rivr/core/models/favorite_river.dart';
import 'package:rivr/core/models/user_settings.dart';
import 'package:rivr/core/models/hourly_flow_data.dart';
import 'package:rivr/core/models/forecast_chart_data.dart';
import 'package:rivr/core/services/i_auth_service.dart';
import 'package:rivr/core/services/auth_service.dart';
import 'package:rivr/core/services/i_forecast_service.dart';
import 'package:rivr/core/services/i_noaa_api_service.dart';
import 'package:rivr/core/services/i_favorites_service.dart';
import 'package:rivr/core/services/i_fcm_service.dart';
import 'package:rivr/core/services/i_cache_service.dart';
import 'package:rivr/core/services/i_reach_cache_service.dart';
import 'package:rivr/core/services/i_user_settings_service.dart';
import 'package:rivr/core/services/i_background_image_service.dart';
import 'package:rivr/core/services/background_image_service.dart';
import 'package:rivr/core/services/i_flow_unit_preference_service.dart';

// ---------------------------------------------------------------------------
// MockAuthService
// ---------------------------------------------------------------------------

class MockAuthService implements IAuthService {
  final StreamController<fb.User?> _authStateController =
      StreamController<fb.User?>.broadcast();

  MockUser? _signedInUser;
  bool _emailVerified = false;

  /// Pre-registered accounts: email -> {password, firstName, lastName}
  final Map<String, Map<String, String>> _registeredAccounts = {};

  MockAuthService();

  /// Register a user in advance so signIn can succeed.
  void seedUser({
    required String email,
    required String password,
    String firstName = 'Test',
    String lastName = 'User',
    bool emailVerified = true,
  }) {
    _registeredAccounts[email] = {
      'password': password,
      'firstName': firstName,
      'lastName': lastName,
    };
    _emailVerified = emailVerified;
  }

  @override
  fb.User? get currentUser => _signedInUser;

  @override
  Stream<fb.User?> get authStateChanges => _authStateController.stream;

  @override
  bool get isSignedIn => _signedInUser != null;

  @override
  Future<AuthResult> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    await Future.delayed(const Duration(milliseconds: 50));
    final account = _registeredAccounts[email];
    if (account == null || account['password'] != password) {
      return AuthResult.failure('Invalid email or password');
    }
    _signedInUser = MockUser(
      uid: 'test-uid-${email.hashCode}',
      email: email,
      displayName: '${account['firstName']} ${account['lastName']}',
      isEmailVerified: _emailVerified,
    );
    _authStateController.add(_signedInUser);
    return AuthResult.success(_signedInUser);
  }

  @override
  Future<AuthResult> registerWithEmailAndPassword({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    await Future.delayed(const Duration(milliseconds: 50));
    if (_registeredAccounts.containsKey(email)) {
      return AuthResult.failure('Email already in use');
    }
    _registeredAccounts[email] = {
      'password': password,
      'firstName': firstName,
      'lastName': lastName,
    };
    _signedInUser = MockUser(
      uid: 'test-uid-${email.hashCode}',
      email: email,
      displayName: '$firstName $lastName',
      isEmailVerified: false,
    );
    _authStateController.add(_signedInUser);
    return AuthResult.success(_signedInUser);
  }

  @override
  Future<AuthResult> sendPasswordResetEmail({required String email}) async {
    await Future.delayed(const Duration(milliseconds: 50));
    if (email.isEmpty) return AuthResult.failure('Email is required');
    return AuthResult.success(null, message: 'Password reset email sent');
  }

  @override
  Future<AuthResult> signOut() async {
    await Future.delayed(const Duration(milliseconds: 50));
    _signedInUser = null;
    _authStateController.add(null);
    return AuthResult.success(null, message: 'Signed out');
  }

  @override
  Future<bool> isBiometricAvailable() async => false;

  @override
  Future<bool> isBiometricEnabled() async => false;

  @override
  Future<AuthResult> enableBiometricLogin() async =>
      AuthResult.failure('Not available in tests');

  @override
  Future<AuthResult> disableBiometricLogin() async =>
      AuthResult.failure('Not available in tests');

  @override
  Future<AuthResult> signInWithBiometrics() async =>
      AuthResult.failure('Not available in tests');

  @override
  Future<AuthResult> updateDisplayName(String displayName) async =>
      AuthResult.success(_signedInUser);

  @override
  Future<void> reloadUser() async {}

  @override
  Future<AuthResult> sendEmailVerification() async {
    return AuthResult.success(_signedInUser,
        message: 'Verification email sent');
  }

  @override
  Future<bool> checkEmailVerified() async => _emailVerified;

  /// Test helper: simulate the user verifying their email.
  void simulateEmailVerification() {
    _emailVerified = true;
    if (_signedInUser != null) {
      _signedInUser = MockUser(
        uid: _signedInUser!.uid,
        email: _signedInUser!.email!,
        displayName: _signedInUser!.displayName,
        isEmailVerified: true,
      );
      _authStateController.add(_signedInUser);
    }
  }

  void dispose() {
    _authStateController.close();
  }
}

// ---------------------------------------------------------------------------
// MockForecastService
// ---------------------------------------------------------------------------

class MockForecastService implements IForecastService {
  ForecastResponse? _stubbedResponse;
  bool shouldFail = false;
  String failureMessage = 'Mock forecast error';
  Duration delay = const Duration(milliseconds: 50);

  void stubResponse(ForecastResponse response) {
    _stubbedResponse = response;
  }

  ForecastResponse get _defaultResponse {
    if (_stubbedResponse != null) return _stubbedResponse!;
    final reach = ReachData(
      reachId: '23021904',
      riverName: 'Deep Creek',
      latitude: 47.6588,
      longitude: -117.426,
      availableForecasts: [
        'analysis_assimilation',
        'short_range',
        'medium_range',
        'long_range',
      ],
      cachedAt: DateTime.now(),
    );
    return ForecastResponse(
      reach: reach,
      analysisAssimilation: ForecastSeries(
        referenceTime: DateTime.now().subtract(const Duration(hours: 1)),
        units: 'CFS',
        data: [ForecastPoint(validTime: DateTime.now(), flow: 150.0)],
      ),
      shortRange: ForecastSeries(
        referenceTime: DateTime.now(),
        units: 'CFS',
        data: List.generate(
          18,
          (i) => ForecastPoint(
            validTime: DateTime.now().add(Duration(hours: i)),
            flow: 150.0 + i * 2.0,
          ),
        ),
      ),
      mediumRange: {
        'mean': ForecastSeries(
          referenceTime: DateTime.now(),
          units: 'CFS',
          data: List.generate(
            10,
            (i) => ForecastPoint(
              validTime: DateTime.now().add(Duration(days: i)),
              flow: 160.0 + i * 5.0,
            ),
          ),
        ),
      },
      longRange: {
        'mean': ForecastSeries(
          referenceTime: DateTime.now(),
          units: 'CFS',
          data: List.generate(
            30,
            (i) => ForecastPoint(
              validTime: DateTime.now().add(Duration(days: i)),
              flow: 140.0 + i * 3.0,
            ),
          ),
        ),
      },
    );
  }

  @override
  Future<ForecastResponse> loadOverviewData(String reachId) async {
    await Future.delayed(delay);
    if (shouldFail) throw Exception(failureMessage);
    return _defaultResponse;
  }

  @override
  Future<ForecastResponse> loadSupplementaryData(
    String reachId,
    ForecastResponse existingData,
  ) async {
    await Future.delayed(delay);
    if (shouldFail) throw Exception(failureMessage);
    return _defaultResponse;
  }

  @override
  Future<ForecastResponse> loadCompleteReachData(String reachId) async {
    await Future.delayed(delay);
    if (shouldFail) throw Exception(failureMessage);
    return _defaultResponse;
  }

  @override
  Future<ForecastResponse> loadSpecificForecast(
    String reachId,
    String forecastType,
  ) async {
    await Future.delayed(delay);
    if (shouldFail) throw Exception(failureMessage);
    return _defaultResponse;
  }

  @override
  Future<ForecastResponse> refreshReachData(String reachId) async {
    await Future.delayed(delay);
    if (shouldFail) throw Exception(failureMessage);
    return _defaultResponse;
  }

  @override
  Future<bool> isReachCached(String reachId) async => false;

  @override
  Future<Map<String, dynamic>> getCacheStats() async => {'size': 0};

  @override
  Future<ForecastResponse> loadCurrentFlowOnly(String reachId) async {
    await Future.delayed(delay);
    if (shouldFail) throw Exception(failureMessage);
    return _defaultResponse;
  }

  @override
  Future<ReachData> loadBasicReachInfo(String reachId) async {
    await Future.delayed(delay);
    return _defaultResponse.reach;
  }

  @override
  ForecastResponse mergeCurrentFlowData(
    ForecastResponse existing,
    ForecastResponse newFlowData,
  ) =>
      existing;

  @override
  double? getCurrentFlow(ForecastResponse forecast,
      {String? preferredType}) =>
      150.0;

  @override
  String getFlowCategory(ForecastResponse forecast,
      {String? preferredType}) =>
      'normal';

  @override
  List<String> getAvailableForecastTypes(ForecastResponse forecast) =>
      ['analysis_assimilation', 'short_range', 'medium_range', 'long_range'];

  @override
  bool hasEnsembleData(ForecastResponse forecast) => true;

  @override
  Map<String, dynamic> getEnsembleSummary(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      {'memberCount': 7, 'mean': 160.0};

  @override
  List<HourlyFlowDataPoint> getShortRangeHourlyData(
      ForecastResponse forecast) {
    return List.generate(
      6,
      (i) => HourlyFlowDataPoint(
        validTime: DateTime.now().add(Duration(hours: i + 1)),
        flow: 150.0 + i * 2.0,
      ),
    );
  }

  @override
  List<HourlyFlowDataPoint> getAllShortRangeHourlyData(
      ForecastResponse forecast) {
    return List.generate(
      18,
      (i) => HourlyFlowDataPoint(
        validTime: DateTime.now().add(Duration(hours: i)),
        flow: 150.0 + i * 2.0,
      ),
    );
  }

  @override
  List<EnsembleStatPoint> getEnsembleStatistics(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      [];

  @override
  bool hasMultipleEnsembleMembers(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      false;

  @override
  Map<String, List<ChartData>> getEnsembleSeriesForChart(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      {};

  @override
  List<ChartDataPoint> getEnsembleReferenceData(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      [];

  @override
  void clearUnitDependentCaches() {}

  @override
  void clearComputedCaches() {}

  @override
  Future<ReachDetailsData> loadReachDetailsData(String reachId) async {
    await Future.delayed(delay);
    if (shouldFail) throw Exception(failureMessage);
    return const ReachDetailsData(
      riverName: 'Deep Creek',
      formattedLocation: 'Spokane, WA',
      currentFlow: 150.0,
      flowCategory: 'normal',
      latitude: 47.6588,
      longitude: -117.426,
      isClassificationAvailable: true,
    );
  }
}

// ---------------------------------------------------------------------------
// MockNoaaApiService
// ---------------------------------------------------------------------------

class MockNoaaApiService implements INoaaApiService {
  bool shouldFail = false;

  @override
  Future<Map<String, dynamic>> fetchReachInfo(String reachId,
      {bool isOverview = false}) async {
    return {
      'reachId': reachId,
      'name': 'Deep Creek',
      'latitude': 47.6588,
      'longitude': -117.426,
      'streamflow': ['short_range', 'medium_range', 'long_range'],
    };
  }

  @override
  Future<Map<String, dynamic>> fetchCurrentFlowOnly(String reachId) async {
    return {'flow': 150.0, 'units': 'CFS'};
  }

  @override
  Future<List<dynamic>> fetchReturnPeriods(String reachId) async {
    return [
      {
        'feature_id': reachId,
        'return_period_2': 100.0,
        'return_period_5': 200.0,
        'return_period_10': 300.0,
        'return_period_25': 400.0,
      }
    ];
  }

  @override
  Future<Map<String, dynamic>> fetchForecast(String reachId, String series,
      {bool isOverview = false}) async {
    return {};
  }

  @override
  Future<Map<String, dynamic>> fetchOverviewData(String reachId) async {
    return {};
  }

  @override
  Future<Map<String, dynamic>> fetchAllForecasts(String reachId) async {
    return {};
  }
}

// ---------------------------------------------------------------------------
// MockFavoritesService
// ---------------------------------------------------------------------------

class MockFavoritesService implements IFavoritesService {
  List<FavoriteRiver> _favorites = [];
  bool shouldFail = false;

  void seedFavorites(List<FavoriteRiver> favorites) {
    _favorites = List.from(favorites);
  }

  @override
  Future<List<FavoriteRiver>> loadFavorites() async {
    if (shouldFail) throw Exception('Failed to load favorites');
    return List.from(_favorites);
  }

  @override
  Future<bool> saveFavorites(List<FavoriteRiver> favorites) async {
    if (shouldFail) return false;
    _favorites = List.from(favorites);
    return true;
  }

  @override
  Future<bool> addFavorite(String reachId,
      {String? customName, double? latitude, double? longitude}) async {
    if (shouldFail) return false;
    _favorites.add(FavoriteRiver(
      reachId: reachId,
      customName: customName,
      displayOrder: _favorites.length,
      latitude: latitude,
      longitude: longitude,
    ));
    return true;
  }

  @override
  Future<bool> removeFavorite(String reachId) async {
    if (shouldFail) return false;
    _favorites.removeWhere((f) => f.reachId == reachId);
    return true;
  }

  @override
  Future<bool> isFavorite(String reachId) async {
    return _favorites.any((f) => f.reachId == reachId);
  }

  @override
  Future<bool> reorderFavorites(List<FavoriteRiver> reorderedFavorites) async {
    if (shouldFail) return false;
    _favorites = List.from(reorderedFavorites);
    return true;
  }

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
    if (shouldFail) return false;
    final index = _favorites.indexWhere((f) => f.reachId == reachId);
    if (index == -1) return false;
    _favorites[index] = _favorites[index].copyWith(
      customName: customName,
      riverName: riverName,
      customImageAsset: customImageAsset,
      lastKnownFlow: lastKnownFlow,
      lastUpdated: lastUpdated,
      latitude: latitude,
      longitude: longitude,
    );
    return true;
  }

  @override
  Future<int> getFavoritesCount() async => _favorites.length;

  @override
  Future<bool> clearAllFavorites() async {
    _favorites.clear();
    return true;
  }
}

// ---------------------------------------------------------------------------
// MockFCMService
// ---------------------------------------------------------------------------

class MockFCMService implements IFCMService {
  NotificationPermissionResult permissionResult =
      NotificationPermissionResult.granted;

  @override
  set navigatorKey(GlobalKey<NavigatorState> key) {}

  @override
  Future<bool> initialize() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  void setupNotificationListeners() {}

  @override
  Future<String?> getAndSaveToken(String userId) async => 'mock-fcm-token';

  @override
  Future<NotificationPermissionResult> enableNotifications(
      String userId) async {
    return permissionResult;
  }

  @override
  Future<void> disableNotifications(String userId) async {}

  @override
  Future<bool> isEnabledForUser(String userId) async => false;

  @override
  Future<void> refreshTokenIfNeeded(String userId) async {}

  @override
  void clearCache() {}
}

// ---------------------------------------------------------------------------
// MockCacheService
// ---------------------------------------------------------------------------

class MockCacheService implements ICacheService {
  final Map<String, dynamic> _store = {};
  bool _isReady = true;

  @override
  Future<void> initialize() async {
    _isReady = true;
  }

  @override
  bool get isReady => _isReady;

  @override
  Future<void> storeAuthToken(String token) async =>
      _store['authToken'] = token;
  @override
  Future<String?> getAuthToken() async => _store['authToken'] as String?;

  @override
  Future<void> storeAuthData({
    required String userId,
    required String email,
    String? authToken,
  }) async {
    _store['userId'] = userId;
    _store['email'] = email;
    if (authToken != null) _store['authToken'] = authToken;
    _store['lastLogin'] = DateTime.now().toIso8601String();
  }

  @override
  Future<String?> getUserId() async => _store['userId'] as String?;
  @override
  Future<String?> getUserEmail() async => _store['email'] as String?;
  @override
  Future<DateTime?> getLastLogin() async {
    final str = _store['lastLogin'] as String?;
    return str != null ? DateTime.parse(str) : null;
  }

  @override
  Future<bool> hasAuthData() async => _store.containsKey('userId');
  @override
  Future<void> clearAuthData() async {
    _store.remove('userId');
    _store.remove('email');
    _store.remove('authToken');
    _store.remove('lastLogin');
  }

  @override
  Future<void> cacheBiometricAvailable(bool available) async =>
      _store['biometricAvailable'] = available;
  @override
  bool? getCachedBiometricAvailable() =>
      _store['biometricAvailable'] as bool?;

  @override
  Future<void> cacheBiometricEnabled(bool enabled) async =>
      _store['biometricEnabled'] = enabled;
  @override
  bool? getCachedBiometricEnabled() => _store['biometricEnabled'] as bool?;

  @override
  Future<void> cacheBiometricType(String type) async =>
      _store['biometricType'] = type;
  @override
  String? getCachedBiometricType() => _store['biometricType'] as String?;
  @override
  Future<void> clearBiometricPreferences() async {
    _store.remove('biometricAvailable');
    _store.remove('biometricEnabled');
    _store.remove('biometricType');
  }

  @override
  Future<List<Map<String, dynamic>>> getRecentSearches() async => [];
  @override
  Future<void> storeRecentSearches(
      List<Map<String, dynamic>> searches) async {}
  @override
  Future<List<Map<String, dynamic>>> addRecentSearch(
      Map<String, dynamic> searchData) async {
    return [searchData];
  }

  @override
  Future<void> clearRecentSearches() async {}
  @override
  Future<int> getRecentSearchesCount() async => 0;

  @override
  Future<void> storeString(String key, String value) async =>
      _store[key] = value;
  @override
  String? getString(String key) => _store[key] as String?;

  @override
  Future<void> storeBool(String key, bool value) async =>
      _store[key] = value;
  @override
  bool? getBool(String key) => _store[key] as bool?;

  @override
  Future<void> storeInt(String key, int value) async => _store[key] = value;
  @override
  int? getInt(String key) => _store[key] as int?;

  @override
  Future<void> remove(String key) async => _store.remove(key);
  @override
  Future<void> clearAll() async => _store.clear();
  @override
  Future<void> clearEverything() async => _store.clear();
  @override
  Future<int> getCacheSize() async => _store.length;
  @override
  Future<Set<String>> getAllKeys() async => _store.keys.toSet();
}

// ---------------------------------------------------------------------------
// MockReachCacheService
// ---------------------------------------------------------------------------

class MockReachCacheService implements IReachCacheService {
  final Map<String, ReachData> _cache = {};

  @override
  Future<void> initialize() async {}
  @override
  bool get isReady => true;

  @override
  Future<ReachData?> get(String reachId) async => _cache[reachId];

  @override
  Future<CacheResult<ReachData>?> getWithFreshness(String reachId) async {
    final data = _cache[reachId];
    if (data == null) return null;
    return CacheResult(data: data, freshness: CacheFreshness.fresh);
  }

  @override
  Future<void> store(ReachData reachData) async =>
      _cache[reachData.reachId] = reachData;
  @override
  Future<void> clearReach(String reachId) async => _cache.remove(reachId);
  @override
  Future<void> clear() async => _cache.clear();
  @override
  Future<bool> isCached(String reachId) async => _cache.containsKey(reachId);
  @override
  Future<Map<String, dynamic>> getCacheStats() async =>
      {'size': _cache.length};
  @override
  Map<String, dynamic> getCacheEffectiveness() => {'hitRate': 1.0};
  @override
  Future<void> forceRefresh(String reachId) async {}
  @override
  Future<int> cleanupStaleEntries() async => 0;
}

// ---------------------------------------------------------------------------
// MockUserSettingsService
// ---------------------------------------------------------------------------

class MockUserSettingsService implements IUserSettingsService {
  UserSettings? _settings;

  /// Access the current settings for test assertions or modification.
  UserSettings? get currentSettings => _settings;

  void seedSettings(UserSettings settings) {
    _settings = settings;
  }

  @override
  Future<UserSettings?> getUserSettings(String userId) async => _settings;

  @override
  Future<void> saveUserSettings(UserSettings settings) async =>
      _settings = settings;

  @override
  Future<void> updateUserSettings(
      String userId, Map<String, dynamic> updates) async {}

  @override
  Future<UserSettings?> addCustomBackgroundImage(
      String userId, String imagePath) async {
    _settings = _settings?.addCustomBackground(imagePath);
    return _settings;
  }

  @override
  Future<UserSettings?> removeCustomBackgroundImage(
      String userId, String imagePath) async {
    _settings = _settings?.removeCustomBackground(imagePath);
    return _settings;
  }

  @override
  Future<List<String>> getUserCustomBackgrounds(String userId) async =>
      _settings?.customBackgroundImagePaths ?? [];

  @override
  Future<UserSettings?> validateCustomBackgrounds(String userId) async =>
      _settings;

  @override
  Future<UserSettings?> clearAllCustomBackgrounds(String userId) async {
    _settings = _settings?.clearAllCustomBackgrounds();
    return _settings;
  }

  @override
  Future<UserSettings> createDefaultSettings({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
  }) async {
    final now = DateTime.now();
    _settings = UserSettings(
      userId: userId,
      email: email,
      firstName: firstName,
      lastName: lastName,
      preferredFlowUnit: FlowUnit.cfs,
      preferredTimeFormat: TimeFormat.twelveHour,
      enableNotifications: false,
      enableDarkMode: false,
      favoriteReachIds: [],
      lastLoginDate: now,
      createdAt: now,
      updatedAt: now,
    );
    return _settings!;
  }

  @override
  Future<UserSettings?> syncAfterLogin(String userId) async => _settings;

  @override
  Future<UserSettings?> addFavoriteReach(
      String userId, String reachId) async {
    _settings = _settings?.addFavorite(reachId);
    return _settings;
  }

  @override
  Future<UserSettings?> removeFavoriteReach(
      String userId, String reachId) async {
    _settings = _settings?.removeFavorite(reachId);
    return _settings;
  }

  @override
  Future<UserSettings?> updateTheme(String userId, bool enableDarkMode) async {
    _settings = _settings?.copyWith(enableDarkMode: enableDarkMode);
    return _settings;
  }

  @override
  Future<UserSettings?> updateFlowUnit(
      String userId, FlowUnit flowUnit) async {
    _settings = _settings?.copyWith(preferredFlowUnit: flowUnit);
    return _settings;
  }

  @override
  Future<UserSettings?> updateNotifications(
      String userId, bool enableNotifications) async {
    _settings =
        _settings?.copyWith(enableNotifications: enableNotifications);
    return _settings;
  }

  @override
  Future<UserSettings?> updateNotificationFrequency(
      String userId, int frequency) async {
    _settings = _settings?.copyWith(notificationFrequency: frequency);
    return _settings;
  }

  @override
  void clearCache() {}

  @override
  Future<bool> userHasSettings(String userId) async => _settings != null;

  @override
  Future<void> syncFlowUnitPreference(String userId) async {}
}

// ---------------------------------------------------------------------------
// MockBackgroundImageService
// ---------------------------------------------------------------------------

class MockBackgroundImageService implements IBackgroundImageService {
  @override
  Future<BackgroundImageResult> pickFromGallery(String userId) async =>
      BackgroundImageResult.failure('Not available in tests');

  @override
  Future<BackgroundImageResult> pickFromCamera(String userId) async =>
      BackgroundImageResult.failure('Not available in tests');

  @override
  Future<BackgroundImageResult> showImageSourceSelector({
    required BuildContext context,
    required String userId,
  }) async =>
      BackgroundImageResult.failure('Not available in tests');

  @override
  Future<bool> deleteCustomBackground(String imagePath) async => true;

  @override
  Future<void> cleanupOldBackgrounds(String userId) async {}

  @override
  Future<bool> imageExists(String imagePath) async => false;
}

// ---------------------------------------------------------------------------
// MockFlowUnitPreferenceService
// ---------------------------------------------------------------------------

class MockFlowUnitPreferenceService implements IFlowUnitPreferenceService {
  String _currentUnit = 'CFS';

  @override
  String get currentFlowUnit => _currentUnit;

  @override
  void setFlowUnit(String unit) => _currentUnit = unit.toUpperCase();

  @override
  String normalizeUnit(String unit) => unit.toUpperCase();

  @override
  double convertFlow(double value, String fromUnit, String toUnit) {
    final from = fromUnit.toUpperCase();
    final to = toUnit.toUpperCase();
    if (from == to) return value;
    if (from == 'CMS' && to == 'CFS') return value * 35.3147;
    if (from == 'CFS' && to == 'CMS') return value / 35.3147;
    return value;
  }

  @override
  double convertToPreferredUnit(double value, String fromUnit) =>
      convertFlow(value, fromUnit, _currentUnit);

  @override
  double convertFromPreferredUnit(double value, String toUnit) =>
      convertFlow(value, _currentUnit, toUnit);

  @override
  String getDisplayUnit() => _currentUnit == 'CMS' ? 'm³/s' : 'ft³/s';

  @override
  bool get isCFS => _currentUnit == 'CFS';

  @override
  bool get isCMS => _currentUnit == 'CMS';

  @override
  void resetToDefault() => _currentUnit = 'CFS';
}
