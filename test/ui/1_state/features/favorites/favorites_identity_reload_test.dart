// test/ui/1_state/features/favorites/favorites_identity_reload_test.dart
//
// REGRESSION, build 848 (2026-09-25).
//
// A guest saved two rivers, signed in to an account that already had eight,
// and the screen kept showing the two. Pull-to-refresh did not help.
//
// The data was never wrong — the account document held all ten. The list on
// screen still belonged to the guest, because the favourites list is loaded
// once when the page first appears and `refreshAllFavorites` only refreshes
// the rivers ALREADY in it. Signing in changes who the list belongs to
// without rebuilding the page, so refreshing was faithfully refreshing the
// wrong two rivers.

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
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';

/// Returns whatever the CURRENT identity owns, and counts the loads.
class _SwitchableFavorites implements IFavoritesRepository {
  List<FavoriteRiver> current = const [];
  int loads = 0;

  @override
  Future<ServiceResult<List<FavoriteRiver>>> loadFavorites() async {
    loads++;
    return ServiceResult.success(current);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubCache implements IRiverDataCache {
  @override
  void setPinnedReaches(Set<String> reachIds) {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubFavService implements IFavoritesService {
  @override
  Future<bool> clearAllFavorites() async => true;
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
  late _SwitchableFavorites source;

  FavoritesProvider build() => FavoritesProvider(
        favoritesService: _StubFavService(),
        reachCacheService: _StubReachCache(),
        unitService: _StubUnit(),
        initializeFavorites: InitializeFavoritesUseCase(source),
        addFavoriteUseCase: AddFavoriteUseCase(source),
        removeFavoriteUseCase: RemoveFavoriteUseCase(source),
        reorderFavoritesUseCase: ReorderFavoritesUseCase(source),
        repository: _StubRepo(),
      );

  setUp(() {
    source = _SwitchableFavorites();
    GetIt.I.registerSingleton<IRiverDataCache>(_StubCache());
  });
  tearDown(() => GetIt.I.reset());

  test('signing in replaces the guest list with the account list', () async {
    final p = build();

    // As a guest: two rivers.
    source.current = const [
      FavoriteRiver(reachId: 'guest-a', displayOrder: 0),
      FavoriteRiver(reachId: 'guest-b', displayOrder: 1),
    ];
    await p.ensureLoadedFor('guest-uid');
    expect(p.favorites.map((f) => f.reachId), ['guest-a', 'guest-b']);

    // Sign in: the account owns ten, including the two just merged.
    source.current = const [
      FavoriteRiver(reachId: 'acct-1', displayOrder: 0),
      FavoriteRiver(reachId: 'guest-a', displayOrder: 1),
      FavoriteRiver(reachId: 'guest-b', displayOrder: 2),
    ];
    await p.ensureLoadedFor('account-uid');

    expect(p.favorites.map((f) => f.reachId),
        containsAll(['acct-1', 'guest-a', 'guest-b']),
        reason: "the account's rivers must appear without rebuilding the page");
    expect(p.loadedForUserId, 'account-uid');
  });


  test('a revision bump re-reads for the SAME identity', () async {
    // REGRESSION, build 857 (2026-09-25). Signing in from a guest merges the
    // guest's rivers into the account AFTER Firebase has switched the
    // session. A reload driven by the identity change alone therefore reads
    // the account's list BEFORE the merge lands, and never reloads again —
    // the identity does not change twice. Jerson's merged river only
    // appeared after he deleted a different river, which forced a reload.
    final p = build();

    source.current = const [FavoriteRiver(reachId: 'acct-1', displayOrder: 0)];
    await p.ensureLoadedFor('u', revision: 0);
    expect(p.favorites.map((f) => f.reachId), ['acct-1']);

    // The merge lands and the revision is bumped.
    source.current = const [
      FavoriteRiver(reachId: 'acct-1', displayOrder: 0),
      FavoriteRiver(reachId: 'from-guest', displayOrder: 1),
    ];
    await p.ensureLoadedFor('u', revision: 1);

    expect(p.favorites.map((f) => f.reachId), ['acct-1', 'from-guest'],
        reason: 'the merged river must appear without any other action');
  });

  test('a repeated revision does not reload', () async {
    final p = build();
    await p.ensureLoadedFor('u', revision: 3);
    final after = source.loads;

    await p.ensureLoadedFor('u', revision: 3);

    expect(source.loads, after);
  });

  test('the same identity does not reload', () async {
    final p = build();
    await p.ensureLoadedFor('u');
    final after = source.loads;

    await p.ensureLoadedFor('u');

    expect(source.loads, after,
        reason: 'this runs on every auth notification — it must be cheap');
  });

  test('signing out empties the list rather than leaving it on screen',
      () async {
    final p = build();
    source.current = const [FavoriteRiver(reachId: 'a', displayOrder: 0)];
    await p.ensureLoadedFor('u');
    expect(p.favorites, isNotEmpty);

    await p.ensureLoadedFor(null);

    expect(p.favorites, isEmpty,
        reason: "one account's rivers must never linger for the next person");
    expect(p.loadedForUserId, isNull);
  });
}
