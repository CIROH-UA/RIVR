// test/integration_test/favorites_reorder_test.dart
//
// ADR 0016 swapped `ReorderableListView.builder` for `SliverReorderableList`
// to make the list lazy again. That swap carries two things nothing else
// checks:
//
//   * `SliverReorderableList` attaches NO drag listener of its own, so each
//     item has to be wrapped in a `ReorderableDelayedDragStartListener` —
//     forget it and long-press-to-reorder silently stops working, with no
//     error and every other test still green; and
//   * `onReorderItem` reports an already-adjusted destination index, so the
//     old `if (newIndex > oldIndex) newIndex--` correction has to go. Leave
//     it in and every downward drag lands one row short.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/favorites_page.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart';

import 'helpers/test_app.dart';
import 'helpers/mock_services.dart';

void main() {
  late TestServices services;
  late AuthProvider authProvider;
  late FavoritesProvider favoritesProvider;

  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    for (var i = 0; i < ms ~/ 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({'has_seen_swipe_hint': true});
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    await resetServiceLocator();
    services = TestServices();
    services.seedSignedInUser();
    services.seedFavorites(const [
      FavoriteRiver(
        reachId: 'first',
        riverName: 'Alpha River',
        displayOrder: 0,
        lastKnownFlow: 100,
        storedFlowUnit: 'CFS',
        source: ForecastSource.nwm,
      ),
      FavoriteRiver(
        reachId: 'second',
        riverName: 'Bravo River',
        displayOrder: 1,
        lastKnownFlow: 200,
        storedFlowUnit: 'CFS',
        source: ForecastSource.nwm,
      ),
      FavoriteRiver(
        reachId: 'third',
        riverName: 'Charlie River',
        displayOrder: 2,
        lastKnownFlow: 300,
        storedFlowUnit: 'CFS',
        source: ForecastSource.nwm,
      ),
    ]);
    services.registerAll();

    authProvider = createAuthProvider(services);
    await authProvider.initialize();
    await authProvider.signIn('test@example.com', 'password123');
  });

  tearDown(() async => resetServiceLocator());

  testWidgets('long-press and drag still reorders the list', (tester) async {
    favoritesProvider = createFavoritesProvider(services);
    await tester.pumpWidget(buildTestApp(
      home: const FavoritesPage(),
      services: services,
      authProvider: authProvider,
      favoritesProvider: favoritesProvider,
    ));
    await settle(tester);

    expect(favoritesProvider.favorites.map((f) => f.reachId).toList(),
        ['first', 'second', 'third']);

    // Take hold of the top card and carry it past the one below it. A card
    // is 120 pt tall with 6 pt of margin either side, so one row is 132.
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(FavoriteRiverCard).first));
    await tester.pump(const Duration(milliseconds: 600)); // the long press
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await settle(tester);

    expect(favoritesProvider.favorites.map((f) => f.reachId).toList(),
        ['second', 'first', 'third'],
        reason: 'dragging the first card down one row puts it second — not '
            'third (an unadjusted index) and not nowhere at all (a missing '
            'drag listener)');
  });
}
