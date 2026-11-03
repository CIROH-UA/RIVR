// test/integration_test/one_open_row_test.dart
//
// ADR 0016, the remainder of finding 12. Opening a second row left the first
// one open, so two sets of action buttons sat on screen at once; and a row
// could be left open, scrolled out of sight, and come back open much later
// with nothing to explain it. iOS closes the previous row and closes on
// scroll.
//
// A card cannot see its siblings, so this is coordinated through one
// notifier — which is exactly the kind of wiring that goes quietly missing.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/favorites_page.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/components/slide_action_buttons.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart';

import 'helpers/test_app.dart';
import 'helpers/mock_services.dart';

void main() {
  late TestServices services;
  late AuthProvider authProvider;
  late FavoritesProvider favorites;

  Future<void> settle(WidgetTester tester, [int ms = 900]) async {
    for (var i = 0; i < ms ~/ 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({'has_seen_swipe_hint': true});
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    FavoriteRiverCard.openRow.value = null;
    await resetServiceLocator();
    services = TestServices();
    services.seedSignedInUser();
    services.seedFavorites([
      for (var i = 0; i < 6; i++)
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
    favorites = createFavoritesProvider(services);
  });

  tearDown(() async {
    FavoriteRiverCard.openRow.value = null;
    await resetServiceLocator();
  });

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp(
      home: const FavoritesPage(),
      services: services,
      authProvider: authProvider,
      favoritesProvider: favorites,
    ));
    await settle(tester);
  }

  testWidgets('opening a second row closes the first', (tester) async {
    await pumpList(tester);

    await tester.drag(
        find.byType(FavoriteRiverCard).at(0), const Offset(-260, 0));
    await settle(tester);
    expect(find.byType(SlideActionButtons), findsOneWidget);

    await tester.drag(
        find.byType(FavoriteRiverCard).at(1), const Offset(-260, 0));
    await settle(tester);

    expect(find.byType(SlideActionButtons), findsOneWidget,
        reason: 'two rows of actions used to sit open at the same time');
    expect(FavoriteRiverCard.openRow.value, 'reach-1');
  });

  testWidgets('scrolling the list closes an open row', (tester) async {
    await pumpList(tester);

    await tester.drag(
        find.byType(FavoriteRiverCard).at(0), const Offset(-260, 0));
    await settle(tester);
    expect(find.byType(SlideActionButtons), findsOneWidget);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await settle(tester);

    expect(find.byType(SlideActionButtons), findsNothing,
        reason: 'a row left open and scrolled away used to come back open '
            'much later with nothing to explain it');
    expect(FavoriteRiverCard.openRow.value, isNull);
  });
}
