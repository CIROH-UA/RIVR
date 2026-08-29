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
import 'package:rivr/services/4_infrastructure/river_data/store_backed_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_switch.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';

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
  //
  // ADR 0011 Phase 5: each source is WRAPPED so a favourite is served from the
  // cloud store instead of upstream. This wrapping is what makes guard 1 — "a
  // favourite renders with zero upstream calls from the device" — structural
  // rather than a race. Phase 5's first implementation pushed store documents
  // into the shared cache and relied on the repository finding them fresh, but
  // the repository ALSO revalidates upstream on a stale entry and fetches on a
  // miss, and nothing arbitrated which landed first. Review round 2.
  //
  // The wrapper is transparent: same ForecastSource, same supportedProducts,
  // same validUntil.
  //
  // Guard 7 is "values match what the old path produced, field by field", and
  // there is ONE raw difference: the server writes `formattedLocation: null`
  // while the live path writes `ReachData.formattedLocation`, which is '' when
  // city and state are unknown. It is not observable — every consumer gates on
  // emptiness — and store_backed_data_source_test's "guard 7" group asserts
  // that rather than asserting a raw equality no screen could render. An
  // earlier version of this comment claimed flatly that nothing downstream can
  // tell, which was an assertion with no test behind it (round 5).
  sl.registerLazySingleton<SourceRegistry>(
    () => SourceRegistry([
      StoreBackedDataSource(
        readSwitch: sl<StoreReadSwitch>(),
        // Lazy: the subscription service depends on the repository, which
        // depends on this registry, so resolving it here would be a cycle.
        storeBackedIds: () => sl<StoreSubscriptionService>().watchedIds,
        inner: NwmDataSource(
          geocoder: sl<IGeocodingService>(),
          api: sl<INoaaApiService>(),
          forecastService: sl<IForecastService>(),
          unitService: sl<IFlowUnitPreferenceService>(),
        ),
      ),
      StoreBackedDataSource(
        readSwitch: sl<StoreReadSwitch>(),
        storeBackedIds: () => sl<StoreSubscriptionService>().watchedIds,
        inner: GeoglowsDataSource(
          api: sl<IGeoglowsApiService>(),
          unitService: sl<IFlowUnitPreferenceService>(),
        ),
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

  // ADR 0011 Phase 5 — the store read path. Registered here next to the
  // repository it feeds. Singletons: two subscription services would hold two
  // sets of Firestore listeners and bill for both, and the coordinator is the
  // only thing allowed to attach them.
  sl.registerLazySingleton<StoreReadSwitch>(() => StoreReadSwitch());
  sl.registerLazySingleton<StoreSubscriptionService>(
    () => StoreSubscriptionService(repository: sl<IRiverDataRepository>()),
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
