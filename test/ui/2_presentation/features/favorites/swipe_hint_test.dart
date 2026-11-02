// test/ui/2_presentation/features/favorites/swipe_hint_test.dart
//
// The favourites list used to run a four-panel `tutorial_coach_mark` tour as
// soon as a user saved their first river — a 90%-black overlay explaining
// pull-to-refresh, swipe actions and the settings menu, with a search tip
// chained onto the end and `hideSkip: true`, so there was no way out of it.
//
// It is replaced by a single hint that demonstrates the one thing that is
// genuinely not discoverable: that actions live BEHIND a favourite card. The
// card performs the gesture on itself.
//
// These guards pin the two properties that make it not-invasive:
//   * it reveals the real actions, by moving the real card; and
//   * it puts the card back, and reports completion exactly once, so it is
//     never shown twice and never leaves the row stuck open.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/models/2_usecases/features/favorites/add_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/initialize_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/remove_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/reorder_favorites_usecase.dart';
import 'package:rivr/services/1_contracts/features/favorites/i_favorites_repository.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart';

class _StubUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String normalizeUnit(String unit) => unit;
  @override
  double convertFlow(double value, String from, String to) => value;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubGeocoding implements IGeocodingService {
  @override
  Future<String?> placeLabel(double? lat, double? lon) async => null;
  @override
  Future<Map<String, String?>> reverseGeocode(double lat, double lon) async =>
      const {};
}

class _StubCache implements IRiverDataCache {
  @override
  void setPinnedReaches(Set<String> reachIds) {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubFavService implements IFavoritesService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubReachCache implements IReachCacheService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubRepo implements IRiverDataRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Owns nothing. The card is driven directly by its `favorite` argument, so
/// the provider only has to exist.
class _EmptyFavorites implements IFavoritesRepository {
  @override
  Future<ServiceResult<List<FavoriteRiver>>> loadFavorites() async =>
      ServiceResult.success(const []);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

FavoritesProvider _buildProvider() {
  final source = _EmptyFavorites();
  return FavoritesProvider(
    favoritesService: _StubFavService(),
    reachCacheService: _StubReachCache(),
    unitService: _StubUnit(),
    initializeFavorites: InitializeFavoritesUseCase(source),
    addFavoriteUseCase: AddFavoriteUseCase(source),
    removeFavoriteUseCase: RemoveFavoriteUseCase(source),
    reorderFavoritesUseCase: ReorderFavoritesUseCase(source),
    repository: _StubRepo(),
  );
}

void main() {
  setUp(() {
    GetIt.I.registerSingleton<IRiverDataCache>(_StubCache());
    GetIt.I.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
    GetIt.I.registerSingleton<IGeocodingService>(_StubGeocoding());
  });
  tearDown(() => GetIt.I.reset());

  final favourite = FavoriteRiver(
    reachId: '123',
    riverName: 'Test River',
    displayOrder: 0,
    lastKnownFlow: 100,
    storedFlowUnit: 'CFS',
    source: ForecastSource.nwm,
  );

  Future<void> pumpCard(WidgetTester tester,
      {required bool runHint, VoidCallback? onComplete}) async {
    await tester.pumpWidget(CupertinoApp(
      home: ChangeNotifierProvider<FavoritesProvider>.value(
        value: _buildProvider(),
        child: Center(
          child: SizedBox(
            width: 320,
            height: 220,
            child: FavoriteRiverCard(
              favorite: favourite,
              runSwipeHint: runHint,
              onSwipeHintComplete: onComplete,
            ),
          ),
        ),
      ),
    ));
  }

  /// The hint is a sequence of delays AND animations, so time has to be
  /// advanced in frames — one long `pump` elapses the delays but never ticks
  /// the controller.
  Future<void> advance(WidgetTester tester, int ms) async {
    for (var elapsed = 0; elapsed < ms; elapsed += 50) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The card's offset within its own slide transition. 0 = closed.
  ///
  /// Scoped to the card on purpose: `CupertinoApp` wraps the page in slide
  /// transitions of its own, and reading the outermost one reports a card
  /// that never moves no matter what the hint does.
  double slideDx(WidgetTester tester) {
    final t = tester.widget<SlideTransition>(find.descendant(
      of: find.byType(FavoriteRiverCard),
      matching: find.byType(SlideTransition),
    ));
    return t.position.value.dx;
  }

  testWidgets('without the hint the card never moves', (tester) async {
    await pumpCard(tester, runHint: false);
    await advance(tester, 4000);

    expect(slideDx(tester), 0.0,
        reason: 'a card that was not asked to demonstrate must sit still');
  });

  testWidgets('the hint opens the card, then closes it again', (tester) async {
    await pumpCard(tester, runHint: true);

    // It waits before moving — the list must settle first.
    await advance(tester, 300);
    expect(slideDx(tester), 0.0, reason: 'it must not snatch at the card');

    // Mid-reveal: the card has moved left.
    await advance(tester, 1000);
    expect(slideDx(tester), lessThan(0.0),
        reason: 'the point of the hint is to SHOW the hidden actions');

    // And it puts it back.
    await advance(tester, 2500);
    expect(slideDx(tester), 0.0,
        reason: 'leaving the row stuck open would be worse than not hinting');
  });

  testWidgets('it reports completion exactly once', (tester) async {
    var completions = 0;
    await pumpCard(tester, runHint: true, onComplete: () => completions++);
    await advance(tester, 4000);

    expect(completions, 1,
        reason: 'the page marks the hint seen on this callback — firing it '
            'twice, or never, both break "show it once"');
  });
}
