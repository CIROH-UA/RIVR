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

final sl = GetIt.instance;

/// Register all services in dependency order.
/// Call this once in main() before runApp().
void setupServiceLocator() {
  // Leaf services (no inter-service dependencies)
  sl.registerLazySingleton<IFlowUnitPreferenceService>(
    () => FlowUnitPreferenceService(),
  );
  sl.registerLazySingleton<ICacheService>(() => CacheService());
  sl.registerLazySingleton<IReachCacheService>(() => ReachCacheService());
  sl.registerLazySingleton<IBackgroundImageService>(
    () => BackgroundImageService(),
  );
  sl.registerLazySingleton<IAuthService>(() => AuthService());

  // Services with one dependency
  sl.registerLazySingleton<INoaaApiService>(
    () => NoaaApiService(unitService: sl<IFlowUnitPreferenceService>()),
  );

  // Services with multiple dependencies
  sl.registerLazySingleton<IUserSettingsService>(
    () => UserSettingsService(
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
}
