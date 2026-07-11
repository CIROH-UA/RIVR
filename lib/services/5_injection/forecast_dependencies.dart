import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/api/noaa_api_service.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/services/4_infrastructure/api/geoglows_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/forecast/forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_cache_service.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_forecast_repository.dart';
import 'package:rivr/services/2_coordinators/features/forecast/forecast_repository_impl.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_overview_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_supplementary_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_complete_forecast_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/refresh_forecast_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/get_reach_details_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_specific_forecast_usecase.dart';
import 'package:rivr/models/2_usecases/features/map/get_reach_details_for_map_usecase.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/4_infrastructure/cache/river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/river_data_repository.dart';

void setupForecastDependencies() {
  final sl = GetIt.instance;
  if (sl.isRegistered<INoaaApiService>()) return;

  // Services
  sl.registerLazySingleton<INoaaApiService>(
    () => NoaaApiService(unitService: sl<IFlowUnitPreferenceService>()),
  );

  // GEOGLOWS forecast client (global, non-US rivers). Not yet consumed by the
  // forecast flow — source-routing (NWM vs GEOGLOWS) is the next step.
  sl.registerLazySingleton<IGeoglowsApiService>(
    () => GeoglowsApiService(unitService: sl<IFlowUnitPreferenceService>()),
  );

  sl.registerLazySingleton<IForecastService>(
    () => ForecastService(
      apiService: sl<INoaaApiService>(),
      cacheService: sl<IReachCacheService>(),
      unitService: sl<IFlowUnitPreferenceService>(),
      forecastCacheService: sl<IForecastCacheService>(),
    ),
  );

  // Repository
  sl.registerLazySingleton<IForecastRepository>(
    () => ForecastRepositoryImpl(forecastService: sl<IForecastService>()),
  );

  // Pluggable data sources behind one registry (ADR 0001). Adding a source =
  // one entry here + an IRiverDataSource impl. Consumed by the RiverDataRepository
  // (next step); not yet wired to the UI.
  sl.registerLazySingleton<SourceRegistry>(
    () => SourceRegistry([
      NwmDataSource(
        api: sl<INoaaApiService>(),
        forecastService: sl<IForecastService>(),
        unitService: sl<IFlowUnitPreferenceService>(),
      ),
      GeoglowsDataSource(
        api: sl<IGeoglowsApiService>(),
        unitService: sl<IFlowUnitPreferenceService>(),
      ),
    ]),
  );

  // Shared cache + single-source-of-truth repository (ADR 0001). Self-initializes
  // its disk store on first use. Not yet consumed by the UI (step 5 migrates
  // surfaces onto it).
  sl.registerLazySingleton<IRiverDataCache>(() => RiverDataCache());
  sl.registerLazySingleton<IRiverDataRepository>(
    () => RiverDataRepository(
      cache: sl<IRiverDataCache>(),
      registry: sl<SourceRegistry>(),
    ),
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
