// test/ui/1_state/features/favorites/favorites_provider_pinning_test.dart
//
// ADR 0011 Phase 2: the retention cap must never evict a favourite, and the
// cache learns which reaches are favourites FROM THIS PROVIDER — it pushes the
// pinned set on every membership change via `_updateFavoriteReachIds`.
//
// This is the wiring's only guard. Without it, deleting the push leaves every
// cache-side pinning test green (they call setPinnedReaches directly) while in
// the app nothing ever pins anything and the cap evicts favourites like any
// other reach — the exact "guard asserts a sibling's behaviour, not the code
// under test" failure Phase 1's reviews kept finding.

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/2_usecases/features/favorites/add_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/initialize_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/remove_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/reorder_favorites_usecase.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';

class _RecordingCache implements IRiverDataCache {
  final List<Set<String>> pinnedCalls = [];

  /// Copied, not aliased: the provider passes its LIVE set, so recording the
  /// reference let a later `.clear()` rewrite history and a mutation that
  /// skipped the push entirely still looked like an empty push.
  @override
  void setPinnedReaches(Set<String> reachIds) =>
      pinnedCalls.add(Set.of(reachIds));

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Favorites implements IFavoritesRepository {
  _Favorites(this.list);
  final List<FavoriteRiver> list;

  @override
  Future<ServiceResult<List<FavoriteRiver>>> loadFavorites() async =>
      ServiceResult.success(list);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FailingFavorites implements IFavoritesRepository {
  @override
  Future<ServiceResult<List<FavoriteRiver>>> loadFavorites() async =>
      ServiceResult.failure(
          const ServiceException.network('firestore unavailable'));

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubFavService implements IFavoritesService {
  @override
  Future<bool> clearAllFavorites() async => true;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubForecast implements IForecastService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubReachCache implements IReachCacheService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubRepo implements IRiverDataRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late _RecordingCache cache;

  FavoritesProvider provider(List<FavoriteRiver> favs) => FavoritesProvider(
        favoritesService: _StubFavService(),
        forecastService: _StubForecast(),
        reachCacheService: _StubReachCache(),
        unitService: _StubUnit(),
        initializeFavorites: InitializeFavoritesUseCase(_Favorites(favs)),
        addFavoriteUseCase: AddFavoriteUseCase(_Favorites(favs)),
        removeFavoriteUseCase: RemoveFavoriteUseCase(_Favorites(favs)),
        reorderFavoritesUseCase: ReorderFavoritesUseCase(_Favorites(favs)),
        repository: _StubRepo(),
      );

  setUp(() {
    cache = _RecordingCache();
    GetIt.I.registerSingleton<IRiverDataCache>(cache);
  });
  tearDown(() => GetIt.I.reset());

  test('loading favourites pins their reach ids in the cache', () async {
    final p = provider([
      const FavoriteRiver(reachId: '111', displayOrder: 0),
      const FavoriteRiver(reachId: '222', displayOrder: 1),
    ]);

    await p.initializeAndRefresh();

    expect(cache.pinnedCalls, isNotEmpty,
        reason: 'the cache only knows what to protect if this provider tells '
            'it — nothing else in the app calls setPinnedReaches');
    expect(cache.pinnedCalls.last, {'111', '222'});
  });

  test('an account with no favourites pins the empty set', () async {
    final p = provider(const []);

    await p.initializeAndRefresh();

    expect(cache.pinnedCalls, isNotEmpty);
    expect(cache.pinnedCalls.last, isEmpty,
        reason: 'stale pins from a previous account would shield reaches the '
            'current user never favourited');
  });

  // REGRESSION (Phase 2 round 8, F1 — a live bug): a failed favourites load
  // used to be swallowed to [], which this provider then pushed as "this
  // account has no favourites" — un-pinning every reach and PERSISTING the
  // empty set over pins.json. One Firestore hiccup at startup made every
  // favourite evictable, on this launch and the next.
  test('a failed favourites load leaves the pins untouched', () async {
    final p = FavoritesProvider(
      favoritesService: _StubFavService(),
      forecastService: _StubForecast(),
      reachCacheService: _StubReachCache(),
      unitService: _StubUnit(),
      initializeFavorites: InitializeFavoritesUseCase(_FailingFavorites()),
      addFavoriteUseCase: AddFavoriteUseCase(_FailingFavorites()),
      removeFavoriteUseCase: RemoveFavoriteUseCase(_FailingFavorites()),
      reorderFavoritesUseCase: ReorderFavoritesUseCase(_FailingFavorites()),
      repository: _StubRepo(),
    );

    await p.initializeAndRefresh();

    expect(cache.pinnedCalls, isEmpty,
        reason: 'could-not-load must be distinguishable from has-none: '
            'pushing the empty set here wipes the pins file');
    expect(p.errorMessage, isNotNull,
        reason: 'and the failure is a failure, not a quietly empty account');
  });

  // REGRESSION (round 1, F10): clearAllFavorites cleared the provider's own
  // sets directly and never went through the membership hook, so the cache
  // kept pins for favourites that no longer existed.
  test('clearing all favourites un-pins everything', () async {
    final p = provider([const FavoriteRiver(reachId: '111', displayOrder: 0)]);
    await p.initializeAndRefresh();
    expect(cache.pinnedCalls.last, {'111'});

    await p.clearAllFavorites();

    expect(cache.pinnedCalls.last, isEmpty,
        reason: 'membership changed; the pin set must follow it — this path '
            'used to bypass the hook');
  });

  test('a provider without a registered cache still loads (tests, tools)',
      () async {
    await GetIt.I.reset();

    final p = provider([const FavoriteRiver(reachId: '111', displayOrder: 0)]);

    await p.initializeAndRefresh();
    expect(p.favorites, hasLength(1),
        reason: 'pinning is best-effort wiring, not a load dependency');
  });
}
