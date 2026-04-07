import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/4_infrastructure/favorites/favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/1_contracts/shared/i_auth_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';
import 'package:rivr/services/2_coordinators/features/favorites/favorites_repository_impl.dart';
import 'package:rivr/models/2_usecases/features/favorites/initialize_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/add_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/remove_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/update_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/reorder_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/refresh_all_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/refresh_favorite_flow_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/get_favorite_flow_usecase.dart';

void setupFavoritesDependencies() {
  final sl = GetIt.instance;
  if (sl.isRegistered<IFavoritesService>()) return;

  // Service
  sl.registerLazySingleton<IFavoritesService>(
    () => FavoritesService(
      settingsService: sl<IUserSettingsService>(),
      authService: sl<IAuthService>(),
    ),
  );

  // Repository
  sl.registerLazySingleton<IFavoritesRepository>(
    () => FavoritesRepositoryImpl(
      favoritesService: sl<IFavoritesService>(),
      forecastService: sl<IForecastService>(),
      cacheService: sl<IReachCacheService>(),
      unitService: sl<IFlowUnitPreferenceService>(),
      apiService: sl<INoaaApiService>(),
    ),
  );

  // Use cases
  sl.registerFactory(() => InitializeFavoritesUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => AddFavoriteUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => RemoveFavoriteUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => UpdateFavoriteUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => ReorderFavoritesUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => RefreshAllFavoritesUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => RefreshFavoriteFlowUseCase(sl<IFavoritesRepository>()));
  sl.registerFactory(() => GetFavoriteFlowUseCase(sl<IFavoritesRepository>()));
}
