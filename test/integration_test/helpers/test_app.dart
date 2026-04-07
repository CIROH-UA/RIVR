// integration_test/helpers/test_app.dart
//
// Bootstraps the app with mocked services for integration testing.
// All external dependencies (Firebase, NOAA, FCM, etc.) are replaced
// with in-memory fakes registered via GetIt.

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';
import 'package:rivr/ui/2_presentation/routing/app_router.dart';
import 'package:rivr/services/1_contracts/shared/i_auth_service.dart';
import 'package:rivr/services/1_contracts/shared/i_background_image_service.dart';
import 'package:rivr/services/1_contracts/shared/i_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/services/2_coordinators/features/favorites/favorites_repository_impl.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';
import 'package:rivr/models/2_usecases/features/favorites/initialize_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/add_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/remove_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/reorder_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/get_favorite_flow_usecase.dart';
import 'package:rivr/services/2_coordinators/features/forecast/forecast_repository_impl.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_forecast_repository.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_overview_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_supplementary_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_specific_forecast_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_complete_forecast_usecase.dart';
import 'package:rivr/services/2_coordinators/features/auth/auth_repository_impl.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';
import 'package:rivr/services/2_coordinators/features/settings/settings_repository_impl.dart';
import 'package:rivr/services/1_contracts/features/settings/i_settings_repository.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_up_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_out_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/reset_password_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/enable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/disable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_with_biometrics_usecase.dart';
import 'package:rivr/models/2_usecases/features/settings/sync_settings_after_login_usecase.dart';

import 'mock_services.dart';

/// All mock service instances used by the test app.
/// Access these to configure behavior (e.g., seed users, stub responses).
class TestServices {
  final MockAuthService auth;
  final MockForecastService forecast;
  final MockNoaaApiService noaaApi;
  final MockFavoritesService favorites;
  final MockFCMService fcm;
  final MockCacheService cache;
  final MockReachCacheService reachCache;
  final MockUserSettingsService userSettings;
  final MockBackgroundImageService backgroundImage;
  final MockFlowUnitPreferenceService flowUnit;

  TestServices({
    MockAuthService? auth,
    MockForecastService? forecast,
    MockNoaaApiService? noaaApi,
    MockFavoritesService? favorites,
    MockFCMService? fcm,
    MockCacheService? cache,
    MockReachCacheService? reachCache,
    MockUserSettingsService? userSettings,
    MockBackgroundImageService? backgroundImage,
    MockFlowUnitPreferenceService? flowUnit,
  })  : auth = auth ?? MockAuthService(),
        forecast = forecast ?? MockForecastService(),
        noaaApi = noaaApi ?? MockNoaaApiService(),
        favorites = favorites ?? MockFavoritesService(),
        fcm = fcm ?? MockFCMService(),
        cache = cache ?? MockCacheService(),
        reachCache = reachCache ?? MockReachCacheService(),
        userSettings = userSettings ?? MockUserSettingsService(),
        backgroundImage = backgroundImage ?? MockBackgroundImageService(),
        flowUnit = flowUnit ?? MockFlowUnitPreferenceService();

  /// Register all mocks in the GetIt service locator.
  void registerAll() {
    final sl = GetIt.instance;
    sl.registerSingleton<IAuthService>(auth);
    sl.registerSingleton<IForecastService>(forecast);
    sl.registerSingleton<INoaaApiService>(noaaApi);
    sl.registerSingleton<IFavoritesService>(favorites);
    sl.registerSingleton<IFCMService>(fcm);
    sl.registerSingleton<ICacheService>(cache);
    sl.registerSingleton<IReachCacheService>(reachCache);
    sl.registerSingleton<IUserSettingsService>(userSettings);
    sl.registerSingleton<IBackgroundImageService>(backgroundImage);
    sl.registerSingleton<IFlowUnitPreferenceService>(flowUnit);

    // Forecast repository + use cases (needed by ReachDataProvider)
    final forecastRepo = ForecastRepositoryImpl(forecastService: forecast);
    sl.registerSingleton<IForecastRepository>(forecastRepo);
    sl.registerFactory(() => LoadForecastOverviewUseCase(forecastRepo));
    sl.registerFactory(() => LoadForecastSupplementaryUseCase(forecastRepo));
    sl.registerFactory(() => LoadSpecificForecastUseCase(forecastRepo));
    sl.registerFactory(() => LoadCompleteForecastUseCase(forecastRepo));

    // Favorites repository + use cases (needed by FavoritesProvider)
    final favoritesRepo = FavoritesRepositoryImpl(
      favoritesService: favorites,
      forecastService: forecast,
      cacheService: reachCache,
      unitService: flowUnit,
      apiService: noaaApi,
    );
    sl.registerSingleton<IFavoritesRepository>(favoritesRepo);
    sl.registerFactory(() => InitializeFavoritesUseCase(favoritesRepo));
    sl.registerFactory(() => AddFavoriteUseCase(favoritesRepo));
    sl.registerFactory(() => RemoveFavoriteUseCase(favoritesRepo));
    sl.registerFactory(() => ReorderFavoritesUseCase(favoritesRepo));
    sl.registerFactory(() => GetFavoriteFlowUseCase(favoritesRepo));

    // Auth repository + use cases (needed by AuthProvider)
    final authRepo = AuthRepositoryImpl(
      authService: auth,
      settingsService: userSettings,
    );
    sl.registerSingleton<IAuthRepository>(authRepo);
    sl.registerFactory(() => SignInUseCase(authRepo));
    sl.registerFactory(() => SignUpUseCase(authRepo));
    sl.registerFactory(() => SignOutUseCase(authRepo));
    sl.registerFactory(() => ResetPasswordUseCase(authRepo));
    sl.registerFactory(() => EnableBiometricUseCase(authRepo));
    sl.registerFactory(() => DisableBiometricUseCase(authRepo));
    sl.registerFactory(() => SignInWithBiometricsUseCase(authRepo));

    // Settings repository + sync use case (needed by AuthProvider)
    final settingsRepo = SettingsRepositoryImpl(settingsService: userSettings);
    sl.registerSingleton<ISettingsRepository>(settingsRepo);
    sl.registerFactory(() => SyncSettingsAfterLoginUseCase(settingsRepo));
  }

  /// Seed a default signed-in user with settings.
  void seedSignedInUser({
    String email = 'test@example.com',
    String password = 'password123',
    String firstName = 'Test',
    String lastName = 'User',
  }) {
    auth.seedUser(
      email: email,
      password: password,
      firstName: firstName,
      lastName: lastName,
      emailVerified: true,
    );
    final now = DateTime.now();
    userSettings.seedSettings(UserSettings(
      userId: 'test-uid-${email.hashCode}',
      email: email,
      firstName: firstName,
      lastName: lastName,
      preferredFlowUnit: FlowUnit.cfs,
      preferredTimeFormat: TimeFormat.twelveHour,
      enableNotifications: false,
      favoriteReachIds: [],
      lastLoginDate: now,
      createdAt: now,
      updatedAt: now,
    ));
  }

  /// Seed favorites for the signed-in user.
  /// Also stubs the forecast service to return matching river names so
  /// background refreshes don't overwrite seeded data.
  void seedFavorites(List<FavoriteRiver> favs) {
    favorites.seedFavorites(favs);
    for (final fav in favs) {
      final reach = ReachData(
        reachId: fav.reachId,
        riverName: fav.displayName,
        latitude: fav.latitude ?? 47.0,
        longitude: fav.longitude ?? -117.0,
        availableForecasts: ['analysis_assimilation', 'short_range'],
        cachedAt: DateTime.now(),
      );
      forecast.stubReachResponse(
        fav.reachId,
        ForecastResponse(
          reach: reach,
          analysisAssimilation: ForecastSeries(
            referenceTime: DateTime.now().subtract(const Duration(hours: 1)),
            units: 'CFS',
            data: [
              ForecastPoint(
                validTime: DateTime.now(),
                flow: fav.lastKnownFlow ?? 150.0,
              ),
            ],
          ),
          mediumRange: {},
          longRange: {},
        ),
      );
    }
  }
}

/// Reset the GetIt service locator between tests.
Future<void> resetServiceLocator() async {
  await GetIt.instance.reset();
}

/// Create the providers needed by the app.
/// Providers are created with injected mock services so they never
/// fall back to GetIt (though GetIt is also populated as a safety net
/// for code paths that access it directly).
AuthProvider createAuthProvider(TestServices services) {
  final authRepo = AuthRepositoryImpl(
    authService: services.auth,
    settingsService: services.userSettings,
  );
  final settingsRepo = SettingsRepositoryImpl(
    settingsService: services.userSettings,
  );
  return AuthProvider(
    authRepository: authRepo,
    signInUseCase: SignInUseCase(authRepo),
    signUpUseCase: SignUpUseCase(authRepo),
    signOutUseCase: SignOutUseCase(authRepo),
    resetPasswordUseCase: ResetPasswordUseCase(authRepo),
    enableBiometricUseCase: EnableBiometricUseCase(authRepo),
    disableBiometricUseCase: DisableBiometricUseCase(authRepo),
    signInWithBiometricsUseCase: SignInWithBiometricsUseCase(authRepo),
    syncSettingsUseCase: SyncSettingsAfterLoginUseCase(settingsRepo),
    fcmService: services.fcm,
  );
}

FavoritesProvider createFavoritesProvider(TestServices services) {
  final favoritesRepo = FavoritesRepositoryImpl(
    favoritesService: services.favorites,
    forecastService: services.forecast,
    cacheService: services.reachCache,
    unitService: services.flowUnit,
    apiService: services.noaaApi,
  );
  return FavoritesProvider(
    favoritesService: services.favorites,
    forecastService: services.forecast,
    reachCacheService: services.reachCache,
    unitService: services.flowUnit,
    getFavoriteFlowUseCase: GetFavoriteFlowUseCase(favoritesRepo),
  );
}

ReachDataProvider createReachDataProvider(TestServices services) {
  return ReachDataProvider(forecastService: services.forecast);
}

/// Builds a testable CupertinoApp with all providers and mock services.
///
/// [home] is the initial widget to display.
/// [services] provides the mock instances; call [TestServices.registerAll]
/// before building the app.
Widget buildTestApp({
  required Widget home,
  required TestServices services,
  AuthProvider? authProvider,
  FavoritesProvider? favoritesProvider,
  ReachDataProvider? reachDataProvider,
}) {
  final auth = authProvider ?? createAuthProvider(services);
  final favs = favoritesProvider ?? createFavoritesProvider(services);
  final reach = reachDataProvider ?? createReachDataProvider(services);

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<FavoritesProvider>.value(value: favs),
      ChangeNotifierProvider<ReachDataProvider>.value(value: reach),
    ],
    child: CupertinoApp(
      debugShowCheckedModeBanner: false,
      onGenerateRoute: AppRouter.onGenerateRoute,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    ),
  );
}

/// Create test FavoriteRiver instances for seeding.
FavoriteRiver createTestFavorite({
  required String reachId,
  String? riverName,
  String? customName,
  int displayOrder = 0,
  double? lastKnownFlow,
  String? storedFlowUnit,
  DateTime? lastUpdated,
  double? latitude,
  double? longitude,
}) {
  return FavoriteRiver(
    reachId: reachId,
    riverName: riverName ?? 'River $reachId',
    customName: customName,
    displayOrder: displayOrder,
    lastKnownFlow: lastKnownFlow ?? 150.0,
    storedFlowUnit: storedFlowUnit ?? 'CFS',
    lastUpdated: lastUpdated ?? DateTime.now(),
    latitude: latitude ?? 47.0,
    longitude: longitude ?? -117.0,
  );
}
