// test/integration_test/favorites_list_lazy_test.dart
//
// ADR 0016 finding 9. The favourites list was a `ReorderableListView.builder`
// with `shrinkWrap: true` and `NeverScrollableScrollPhysics` inside a
// `SliverToBoxAdapter`. shrinkWrap lays every item out immediately, so the
// list was not lazy — and every favourite card owns a VideoPlayerController.
// Twenty favourites meant twenty video decoders at once, which is why the
// card staggers its own video start by `100 ms × cardIndex` to keep Android
// from running out of decoder slots.
//
// `SliverReorderableList` builds only what is near the viewport.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/favorites_page.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart';

import 'helpers/test_app.dart';
import 'helpers/mock_services.dart';

void main() {
  /// `pumpAndSettle` does not return with 30 cards: each one schedules its
  /// own staggered video-init delay, so a frame is always pending. Pump a
  /// bounded stretch instead.
  Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
    for (var i = 0; i < ms ~/ 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  late TestServices services;
  late AuthProvider authProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'has_seen_swipe_hint': true});
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    await resetServiceLocator();
    services = TestServices();
    services.seedSignedInUser();
    services.seedFavorites([
      for (var i = 0; i < 30; i++)
        FavoriteRiver(
          reachId: 'reach-$i',
          riverName: 'River $i',
          displayOrder: i,
          lastKnownFlow: 100.0 + i,
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

  testWidgets('30 favourites do not all get built at once', (tester) async {
    await tester.pumpWidget(buildTestApp(
      home: const FavoritesPage(),
      services: services,
      authProvider: authProvider,
      favoritesProvider: createFavoritesProvider(services),
    ));
    await settle(tester);

    final built = find.byType(FavoriteRiverCard).evaluate().length;

    expect(built, greaterThan(0), reason: 'the list must render something');
    expect(built, lessThan(30),
        reason: 'a lazy sliver builds the visible window plus a cache '
            'extent, never all 30. Each card it builds starts a video '
            'player, so "all of them" is a decoder-slot problem, not just '
            'wasted layout');
  });

  testWidgets('scrolling builds the ones further down', (tester) async {
    await tester.pumpWidget(buildTestApp(
      home: const FavoritesPage(),
      services: services,
      authProvider: authProvider,
      favoritesProvider: createFavoritesProvider(services),
    ));
    await settle(tester);

    expect(find.text('River 25'), findsNothing);

    final list = find.byType(Scrollable).first;
    for (var i = 0; i < 20 && find.text('River 25').evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -400));
      await settle(tester, 300);
    }

    // Drain the staggered video-init delays of every card that was built
    // and then scrolled away, or the binding reports a pending timer at
    // teardown. The stagger is 100 ms x cardIndex, so 30 cards need ~3 s.
    await settle(tester, 4000);

    expect(find.text('River 25'), findsOneWidget,
        reason: 'laziness must not cost reachability');
  });
}
