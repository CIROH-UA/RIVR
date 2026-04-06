// lib/core/di/service_locator.dart

import 'package:get_it/get_it.dart';
import '../services/i_flow_unit_preference_service.dart';
import '../services/flow_unit_preference_service.dart';
import '../services/i_cache_service.dart';
import '../services/cache_service.dart';
import '../services/i_reach_cache_service.dart';
import '../services/reach_cache_service.dart';
import '../services/i_background_image_service.dart';
import '../services/background_image_service.dart';
import '../services/i_auth_service.dart';
import '../services/auth_service.dart';
import '../services/i_noaa_api_service.dart';
import '../services/noaa_api_service.dart';
import '../services/i_forecast_service.dart';
import '../services/forecast_service.dart';
import '../services/i_favorites_service.dart';
import '../services/favorites_service.dart';
import '../services/i_fcm_service.dart';
import '../services/fcm_service.dart';
import '../services/i_user_settings_service.dart';
import '../services/user_settings_service.dart';
import '../../features/map/services/map_service_factory.dart';

// Repositories
import '../../features/forecast/domain/repositories/i_forecast_repository.dart';
import '../../features/forecast/data/repositories/forecast_repository.dart';
import '../../features/favorites/domain/repositories/i_favorites_repository.dart';
import '../../features/favorites/data/repositories/favorites_repository.dart';
import '../../features/auth/domain/repositories/i_auth_repository.dart';
import '../../features/auth/data/repositories/auth_repository.dart';
import '../../features/settings/domain/repositories/i_settings_repository.dart';
import '../../features/settings/data/repositories/settings_repository_impl.dart';
import '../../features/settings/data/datasources/settings_firestore_datasource.dart';

// Forecast use cases
import '../../features/forecast/domain/usecases/load_forecast_overview_usecase.dart';
import '../../features/forecast/domain/usecases/load_forecast_supplementary_usecase.dart';
import '../../features/forecast/domain/usecases/load_complete_forecast_usecase.dart';
import '../../features/forecast/domain/usecases/refresh_forecast_usecase.dart';
import '../../features/forecast/domain/usecases/get_reach_details_usecase.dart';

// Map use cases
import '../../features/map/domain/usecases/get_reach_details_for_map_usecase.dart';

// Favorites use cases
import '../../features/favorites/domain/usecases/initialize_favorites_usecase.dart';
import '../../features/favorites/domain/usecases/add_favorite_usecase.dart';
import '../../features/favorites/domain/usecases/remove_favorite_usecase.dart';
import '../../features/favorites/domain/usecases/update_favorite_usecase.dart';
import '../../features/favorites/domain/usecases/reorder_favorites_usecase.dart';
import '../../features/favorites/domain/usecases/refresh_all_favorites_usecase.dart';
import '../../features/favorites/domain/usecases/refresh_favorite_flow_usecase.dart';

// Auth use cases
import '../../features/auth/domain/usecases/sign_in_usecase.dart';
import '../../features/auth/domain/usecases/sign_up_usecase.dart';
import '../../features/auth/domain/usecases/sign_out_usecase.dart';
import '../../features/auth/domain/usecases/reset_password_usecase.dart';
import '../../features/auth/domain/usecases/get_auth_state_usecase.dart';
import '../../features/auth/domain/usecases/sign_in_with_biometrics_usecase.dart';
import '../../features/auth/domain/usecases/enable_biometric_usecase.dart';
import '../../features/auth/domain/usecases/disable_biometric_usecase.dart';

// Settings use cases
import '../../features/settings/domain/usecases/get_user_settings_usecase.dart';
import '../../features/settings/domain/usecases/update_flow_unit_usecase.dart';
import '../../features/settings/domain/usecases/update_notifications_usecase.dart';
import '../../features/settings/domain/usecases/update_notification_frequency_usecase.dart';
import '../../features/settings/domain/usecases/sync_settings_after_login_usecase.dart';

final sl = GetIt.instance;

/// Register all services in dependency order.
/// Call this once in main() before runApp().
void setupServiceLocator() {
  // ── Leaf services (no inter-service dependencies) ────────────────────────
  sl.registerLazySingleton<IFlowUnitPreferenceService>(
    () => FlowUnitPreferenceService(),
  );
  sl.registerLazySingleton<ICacheService>(() => CacheService());
  sl.registerLazySingleton<IReachCacheService>(() => ReachCacheService());
  sl.registerLazySingleton<IBackgroundImageService>(
    () => BackgroundImageService(),
  );
  sl.registerLazySingleton<IAuthService>(() => AuthService());

  // ── Datasources ─────────────────────────────────────────────────────────
  sl.registerLazySingleton<SettingsFirestoreDatasource>(
    () => SettingsFirestoreDatasource(),
  );

  // ── Services with one dependency ─────────────────────────────────────────
  sl.registerLazySingleton<INoaaApiService>(
    () => NoaaApiService(unitService: sl<IFlowUnitPreferenceService>()),
  );

  // ── Services with multiple dependencies ──────────────────────────────────
  sl.registerLazySingleton<IUserSettingsService>(
    () => UserSettingsService(
      datasource: sl<SettingsFirestoreDatasource>(),
      unitService: sl<IFlowUnitPreferenceService>(),
      imageService: sl<IBackgroundImageService>(),
    ),
  );

  sl.registerLazySingleton<IFavoritesService>(
    () => FavoritesService(
      settingsService: sl<IUserSettingsService>(),
      authService: sl<IAuthService>(),
    ),
  );

  sl.registerLazySingleton<IForecastService>(
    () => ForecastService(
      apiService: sl<INoaaApiService>(),
      cacheService: sl<IReachCacheService>(),
      unitService: sl<IFlowUnitPreferenceService>(),
    ),
  );

  sl.registerLazySingleton<IFCMService>(
    () => FCMService(settingsService: sl<IUserSettingsService>()),
  );

  // Map service factory (produces fresh page-scoped services)
  sl.registerFactory<MapServiceFactory>(() => MapServiceFactory());

  // ── Repositories ─────────────────────────────────────────────────────────
  sl.registerLazySingleton<IForecastRepository>(
    () => ForecastRepository(forecastService: sl<IForecastService>()),
  );

  sl.registerLazySingleton<IFavoritesRepository>(
    () => FavoritesRepository(
      favoritesService: sl<IFavoritesService>(),
      forecastService: sl<IForecastService>(),
      cacheService: sl<IReachCacheService>(),
      unitService: sl<IFlowUnitPreferenceService>(),
      apiService: sl<INoaaApiService>(),
    ),
  );

  sl.registerLazySingleton<IAuthRepository>(
    () => AuthRepository(
      authService: sl<IAuthService>(),
      settingsService: sl<IUserSettingsService>(),
    ),
  );

  sl.registerLazySingleton<ISettingsRepository>(
    () => SettingsRepositoryImpl(settingsService: sl<IUserSettingsService>()),
  );

  // ── Use cases (registerFactory — stateless, new instance per injection) ──

  // Forecast
  sl.registerFactory(() => LoadForecastOverviewUseCase(sl<IForecastRepository>()));
  sl.registerFactory(() => LoadForecastSupplementaryUseCase(sl<IForecastRepository>()));
  sl.registerFactory(() => LoadCompleteForecastUseCase(sl<IForecastRepository>()));
  sl.registerFactory(() => RefreshForecastUseCase(sl<IForecastRepository>()));
  sl.registerFactory(() => GetReachDetailsUseCase(sl<IForecastRepository>()));

  // Map
  sl.registerFactory(() => GetReachDetailsForMapUseCase(sl<IForecastRepository>()));

  // Favorites
  sl.registerFactory(() => InitializeFavoritesUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => AddFavoriteUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => RemoveFavoriteUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => UpdateFavoriteUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => ReorderFavoritesUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => RefreshAllFavoritesUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => RefreshFavoriteFlowUseCase(sl<IFavoritesRepository>()));

  // Auth
  sl.registerFactory(() => SignInUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => SignUpUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => SignOutUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => ResetPasswordUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => GetAuthStateUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => SignInWithBiometricsUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => EnableBiometricUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => DisableBiometricUseCase(sl<IAuthRepository>()));

  // Settings
  sl.registerFactory(() => GetUserSettingsUseCase(sl<ISettingsRepository>()));
  sl.registerFactory(() => UpdateFlowUnitUseCase(sl<ISettingsRepository>()));
  sl.registerFactory(() => UpdateNotificationsUseCase(sl<ISettingsRepository>()));
  sl.registerFactory(() => UpdateNotificationFrequencyUseCase(sl<ISettingsRepository>()));
  sl.registerFactory(() => SyncSettingsAfterLoginUseCase(sl<ISettingsRepository>()));
}
