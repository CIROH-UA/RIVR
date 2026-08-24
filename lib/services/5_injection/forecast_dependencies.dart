import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/4_infrastructure/geo/geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/api/noaa_api_service.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/services/4_infrastructure/api/geoglows_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/forecast/forecast_service.dart';
import 'package:rivr/services/4_infrastructure/forecast/weekly_outlook_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/4_infrastructure/river_data/nwm_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/4_infrastructure/cache/river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/river_data_repository.dart';

void setupForecastDependencies() {
  final sl = GetIt.instance;

  // Registered BEFORE the early-return below. A harness that registers
  // INoaaApiService itself — the integration test app does — would otherwise
  // short-circuit past this and leave IGeocodingService unregistered, and
  // `GetIt.I<IGeocodingService>()` throws. On the forecast page that throw is
  // caught by the surrounding try and sets the error state, replacing a page
  // that had already rendered correctly. Review found that trap.
  //
  // Behind an interface so the surfaces that geocode can be tested in both
  // directions — that it happens where it should, and that it does NOT happen
  // on the fast path (ADR 0011 Phase 1). Also keeps live Mapbox calls out of
  // the test suite.
  if (!sl.isRegistered<IGeocodingService>()) {
    sl.registerLazySingleton<IGeocodingService>(
        () => const MapboxGeocodingService());
  }

  if (sl.isRegistered<INoaaApiService>()) return;

  // Services

  sl.registerLazySingleton<INoaaApiService>(
    () => NoaaApiService(unitService: sl<IFlowUnitPreferenceService>()),
  );

  // GEOGLOWS forecast client (global, non-US rivers). Consumed through
  // GeoglowsDataSource in the SourceRegistry below, which is how the repository
  // routes a GEOGLOWS reach.
  sl.registerLazySingleton<IGeoglowsApiService>(
    () => GeoglowsApiService(unitService: sl<IFlowUnitPreferenceService>()),
  );

  sl.registerLazySingleton<IForecastService>(
    () => ForecastService(
      apiService: sl<INoaaApiService>(),
      cacheService: sl<IReachCacheService>(),
    ),
  );

  // Pluggable data sources behind one registry (ADR 0001). Adding a source =
  // one entry here + an IRiverDataSource impl. Consumed by the
  // RiverDataRepository, which the map sheet, both forecast-page branches and
  // the weekly outlook all read through as of ADR 0011 Phase 1.
  sl.registerLazySingleton<SourceRegistry>(
    () => SourceRegistry([
      NwmDataSource(
        geocoder: sl<IGeocodingService>(),
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
  // its disk store on first use. Consumed by the map detail sheet, both
  // forecast-page branches and the weekly outlook (ADR 0011 Phase 1), and —
  // load-bearing for Phase 2 — by FavoritesProvider (pinning) and AuthProvider
  // (identity-change clear), both through GetIt. It must stay a SINGLETON:
  // a factory hands the pinner, the clearer and the repository three different
  // caches, and the retention phase goes silently inert. Guarded in
  // forecast_dependencies_test.
  sl.registerLazySingleton<IRiverDataCache>(() => RiverDataCache());
  sl.registerLazySingleton<IRiverDataRepository>(
    () => RiverDataRepository(
      cache: sl<IRiverDataCache>(),
      registry: sl<SourceRegistry>(),
    ),
  );

  // Weekly Outlook assembly (ADR 0011 Phase 3): built HERE so the page
  // resolves one service instead of assembling the fetch graph itself —
  // lib/ui must not reference IForecastService (guard 1).
  sl.registerLazySingleton<WeeklyOutlookService>(
    () => WeeklyOutlookService(
      riverData: sl<IRiverDataRepository>(),
      unitService: sl<IFlowUnitPreferenceService>(),
      geocoder: sl<IGeocodingService>(),
    ),
  );


}
