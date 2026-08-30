// test/ui/1_state/features/favorites/favorites_provider_place_label_test.dart
//
// The GEOGLOWS rename was a one-way door, reported on a device 2026-08-29.
//
// A GEOGLOWS reach publishes no river name, so its card shows a
// reverse-geocoded place instead ("Pitumarca, Peru"). That label was resolved
// asynchronously inside `FavoriteRiverCard`'s own state — and the rename
// dialog is built by the PAGE, which could not see it. So the "Restore to ..."
// button, gated on a river name GEOGLOWS reaches never have, never appeared:
// once renamed, there was no way back short of deleting the favourite.
//
// The card now publishes the resolved label here. These tests pin the
// provider's half of that; `favorites_page` uses `getPlaceLabel` to decide
// whether the button exists at all.

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

class _NoopCache implements IRiverDataCache {
  @override
  void setPinnedReaches(Set<String> reachIds) {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Stub implements IFavoritesService, IReachCacheService,
    IFlowUnitPreferenceService, IRiverDataRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Favorites implements IFavoritesRepository {
  _Favorites(this._favs);
  final List<FavoriteRiver> _favs;

  Future<ServiceResult<List<FavoriteRiver>>> getFavorites() async =>
      ServiceResult.success(_favs);

  @override
  Future<ServiceResult<bool>> removeFavorite(String reachId) async {
    _favs.removeWhere((f) => f.reachId == reachId);
    return ServiceResult.success(true);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  FavoritesProvider provider(List<FavoriteRiver> favs) {
    final repo = _Favorites(favs);
    return FavoritesProvider(
      favoritesService: _Stub(),
      reachCacheService: _Stub(),
      unitService: _Stub(),
      initializeFavorites: InitializeFavoritesUseCase(repo),
      addFavoriteUseCase: AddFavoriteUseCase(repo),
      removeFavoriteUseCase: RemoveFavoriteUseCase(repo),
      reorderFavoritesUseCase: ReorderFavoritesUseCase(repo),
      repository: _Stub(),
    );
  }

  setUp(() => GetIt.I.registerSingleton<IRiverDataCache>(_NoopCache()));
  tearDown(() => GetIt.I.reset());

  test('a cached place label is readable — the whole point', () {
    final p = provider([]);
    p.cachePlaceLabel('620569308', 'Pitumarca, Peru');

    expect(p.getPlaceLabel('620569308'), 'Pitumarca, Peru',
        reason: 'this is what the rename dialog restores TO; without it the '
            'GEOGLOWS rename is a one-way door');
  });

  test('an unknown reach is null, not an empty string', () {
    // Null must stay distinguishable from "resolved to nothing": the page
    // shows no restore button for null, and a button that restores to an
    // empty name would look like a working control that wipes the name.
    expect(provider([]).getPlaceLabel('nope'), isNull);
  });

  test('an empty or blank label is refused', () {
    final p = provider([]);
    p.cachePlaceLabel('1', '');
    p.cachePlaceLabel('2', '   ');

    expect(p.getPlaceLabel('1'), isNull);
    expect(p.getPlaceLabel('2'), isNull,
        reason: 'a geocoder returning whitespace must not create a restore '
            'button that clears the name');
  });

  test('caching does NOT notify listeners', () {
    // Every visible card geocodes independently, so notifying here would
    // rebuild the whole list once per card on first paint — to publish a
    // value nothing rebuilds for. The only reader is the rename dialog, on
    // open. Same reasoning as the return-period unit cached beside it.
    final p = provider([]);
    var notifications = 0;
    p.addListener(() => notifications++);

    p.cachePlaceLabel('620569308', 'Pitumarca, Peru');

    expect(notifications, 0);
  });

  test('removing a favourite forgets its label', () async {
    // Otherwise a reach removed and re-added shows a stale place from a
    // previous session, and the map grows for the life of the process.
    final p = provider([
      const FavoriteRiver(reachId: '620569308', displayOrder: 0),
    ]);
    await p.initializeAndRefresh();
    p.cachePlaceLabel('620569308', 'Pitumarca, Peru');
    expect(p.getPlaceLabel('620569308'), isNotNull);

    await p.removeFavorite('620569308');

    expect(p.getPlaceLabel('620569308'), isNull);
  });

  test('a later label replaces an earlier one', () {
    // Coordinates arrive asynchronously and can be enriched after the first
    // geocode, so the second answer is the better one.
    final p = provider([])
      ..cachePlaceLabel('1', 'Somewhere')
      ..cachePlaceLabel('1', 'Pitumarca, Peru');

    expect(p.getPlaceLabel('1'), 'Pitumarca, Peru');
  });
}
