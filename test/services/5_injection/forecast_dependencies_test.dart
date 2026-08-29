// test/services/5_injection/forecast_dependencies_test.dart
//
// The production wiring itself, exercised.
//
// REGRESSION: `IGeocodingService`'s registration could be deleted outright and
// the whole suite passed — nothing exercised `setupForecastDependencies()`. The
// blast radius was not cosmetic: on the NWM forecast page the place-label fill
// used to sit inside the load's `try`, so a throw from resolving an
// unregistered type landed in the `catch` and replaced a page that had already
// rendered correctly with "Failed to load reach details".
//
// It also caught a live trap: the registration sat *after*
// `if (sl.isRegistered<INoaaApiService>()) return;`, and the integration-test
// harness registers `INoaaApiService` itself — so any integration test reaching
// the sheet or the forecast page would have thrown.

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/5_injection/forecast_dependencies.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_backed_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_switch.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';

class _StubUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
  @override
  double convertFlow(double v, String from, String to) => v;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubNoaa implements INoaaApiService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Registered by a different setup function in production; the Phase 5 wiring
/// tests resolve the whole SourceRegistry, which reaches it through
/// IForecastService.
class _StubReachCache implements IReachCacheService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  final sl = GetIt.instance;

  // AWAITED, both of them. `GetIt.reset()` returns a Future and disposes the
  // singletons it created; the Phase 5 switch's dispose is async. Unawaited,
  // the reset finished DURING the next test and wiped the registration this
  // setUp had just made — which surfaced as "Error while creating
  // INoaaApiService" in a test that never touches it.
  setUp(() async {
    await sl.reset();
    sl.registerLazySingleton<IFlowUnitPreferenceService>(() => _StubUnit());
  });
  tearDown(() async => sl.reset());

  test('the geocoder is registered and resolvable', () {
    setupForecastDependencies();

    expect(sl.isRegistered<IGeocodingService>(), isTrue);
    expect(() => sl<IGeocodingService>(), returnsNormally,
        reason: 'every consumer resolves this at runtime; an unregistered type '
            'throws where the throw is caught and shown as a load failure');
  });

  // REGRESSION: registering INoaaApiService first used to short-circuit past
  // the geocoder registration entirely. The integration harness does exactly
  // this.
  test('it is registered even when another service short-circuits setup', () {
    sl.registerLazySingleton<INoaaApiService>(() => _StubNoaa());

    setupForecastDependencies();

    expect(sl.isRegistered<IGeocodingService>(), isTrue,
        reason: 'the registration must sit above the early-return');
  });

  test('setup is idempotent — calling twice does not throw', () {
    setupForecastDependencies();
    expect(setupForecastDependencies, returnsNormally);
    expect(sl.isRegistered<IGeocodingService>(), isTrue);
  });

  // ADR 0011 Phase 2: the retention wiring rests entirely on this ONE
  // registration being present and being a SINGLETON. FavoritesProvider pins
  // through GetIt, AuthProvider clears through GetIt, RiverDataRepository
  // holds the instance it was constructed with — three consumers, one
  // instance, or the phase is inert. Round 5 proved both failure modes with
  // the whole 1055-test suite green: registerFactory (each consumer gets a
  // throwaway; favourites evictable, sign-out clears nothing) and deleting
  // the registration outright (both isRegistered guards go false; every
  // pin/clear is a silent no-op).
  group('the river-data cache registration (Phase 2 load-bearing)', () {
    test('it is registered', () {
      setupForecastDependencies();

      expect(sl.isRegistered<IRiverDataCache>(), isTrue,
          reason: 'absent, FavoritesProvider and AuthProvider both no-op '
              'behind their isRegistered checks and the phase never runs');
    });

    test('it is one shared instance, not a factory', () {
      setupForecastDependencies();

      expect(identical(sl<IRiverDataCache>(), sl<IRiverDataCache>()), isTrue,
          reason: 'a factory hands the pinner, the clearer and the repository '
              'three different caches — pins protect nothing anyone reads');
    });
  });

  // ADR 0011 Phase 5, review round 3, non-blocking 1 — the FAKE GUARD.
  //
  // Every Phase 5 object was well tested in isolation, and NOTHING asserted
  // any of them was installed. The reviewer unwrapped StoreBackedDataSource
  // here and registered a bare NwmDataSource — deleting the entire read path —
  // and all 1136 tests passed. The pieces were guarded; the wiring was not.
  group('the Phase 5 read path is actually wired in', () {
    setUp(() {
      sl.registerLazySingleton<IReachCacheService>(() => _StubReachCache());
    });

    test('every registered source is store-backed', () {
      setupForecastDependencies();

      final registry = sl<SourceRegistry>();
      for (final src in [ForecastSource.nwm, ForecastSource.geoglows]) {
        expect(registry.forSource(src), isA<StoreBackedDataSource>(),
            reason: 'unwrapped, $src goes straight to upstream and guard 1 — '
                'the phase\'s central guard — is silently off with every '
                'other test still green');
      }
    });

    test('the wrapper keeps each source\'s identity', () {
      setupForecastDependencies();

      final registry = sl<SourceRegistry>();
      // If the wrapper did not delegate `source`, the registry would route
      // both networks to whichever it happened to build first.
      expect(registry.forSource(ForecastSource.nwm).source,
          ForecastSource.nwm);
      expect(registry.forSource(ForecastSource.geoglows).source,
          ForecastSource.geoglows);
    });

    test('the switch and the subscription service are single instances', () {
      setupForecastDependencies();

      expect(identical(sl<StoreReadSwitch>(), sl<StoreReadSwitch>()), isTrue,
          reason: 'two switches means the one main() initialises is not the '
              'one the sources read, and the kill switch never fires');
      expect(
          identical(
              sl<StoreSubscriptionService>(), sl<StoreSubscriptionService>()),
          isTrue,
          reason: 'two subscription services hold two sets of listeners and '
              'only one is ever detached');
    });

    test('the whole graph resolves without an initialised Firebase app', () {
      // Not incidental. These types used to resolve FirebaseRemoteConfig and
      // FirebaseFirestore in their CONSTRUCTORS, which throws with no Firebase
      // app — so the production wiring could not be exercised by any plain
      // unit test, which is precisely how it stayed unguarded.
      setupForecastDependencies();

      expect(() => sl<SourceRegistry>(), returnsNormally);
      expect(() => sl<StoreReadSwitch>(), returnsNormally);
      expect(() => sl<StoreSubscriptionService>(), returnsNormally);
    });
  });
}
