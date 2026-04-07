import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/api/noaa_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/forecast/forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_forecast_repository.dart';
import 'package:rivr/services/2_coordinators/features/forecast/forecast_repository_impl.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_overview_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_supplementary_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_complete_forecast_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/refresh_forecast_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/get_reach_details_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_specific_forecast_usecase.dart';
import 'package:rivr/models/2_usecases/features/map/get_reach_details_for_map_usecase.dart';

void setupForecastDependencies() {
  final sl = GetIt.instance;
  if (sl.isRegistered<INoaaApiService>()) return;

  // Services
  sl.registerLazySingleton<INoaaApiService>(
    () => NoaaApiService(unitService: sl<IFlowUnitPreferenceService>()),
  );

  sl.registerLazySingleton<IForecastService>(
    () => ForecastService(
      apiService: sl<INoaaApiService>(),
      cacheService: sl<IReachCacheService>(),
      unitService: sl<IFlowUnitPreferenceService>(),
    ),
  );

  // Repository
  sl.registerLazySingleton<IForecastRepository>(
    () => ForecastRepositoryImpl(forecastService: sl<IForecastService>()),
  );

  // Forecast use cases
  sl.registerFactory(() => LoadForecastOverviewUseCase(sl<IForecastRepository>()));
  sl.registerFactory(() => LoadForecastSupplementaryUseCase(sl<IForecastRepository>()));
  sl.registerFactory(() => LoadCompleteForecastUseCase(sl<IForecastRepository>()));
  sl.registerFactory(() => RefreshForecastUseCase(sl<IForecastRepository>()));
  sl.registerFactory(() => GetReachDetailsUseCase(sl<IForecastRepository>()));
  sl.registerFactory(() => LoadSpecificForecastUseCase(sl<IForecastRepository>()));

  // Map use case (depends on forecast repository)
  sl.registerFactory(() => GetReachDetailsForMapUseCase(sl<IForecastRepository>()));
}
