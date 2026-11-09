// test/integration_test/swipe_hint_plays_test.dart
//
// ADR 0015, proven by BEHAVIOUR for the first time.
//
// The onboarding hint is carried by three connections between the page and
// the card, and until now all three were guarded only by
// `swipe_hint_wiring_test.dart`, which greps the page's source for
// `runSwipeHint:`, `_resolveSwipeHint()` and
// `CoachMarkService.completeSwipeHint()`. That file says plainly that it is a
// tripwire rather than coverage, and a 2026-11-09 mutation audit showed what
// that costs: **wrap any of those lines in `if (false)` and the whole feature
// is dead with 105 tests green**, because the string the guard greps for is
// still there. The audit counted this mechanism as the largest single source
// of vacuous tests in the suite, and named the swipe-hint guards specifically
// as tests written the week before by someone who believed they were careful.
//
// So this pumps the real `FavoritesPage` with real cards and watches the
// first card MOVE. Nothing here reads the page's source.
//
// Note on the harness: every other favourites test seeds
// `has_seen_swipe_hint: true` precisely so the hint cannot interfere with it
// (CLAUDE.md says so). This is the one file that must seed it false, and it
// also seeds `favorites_visit_count: 1` so that this launch is the SECOND
// arrival, which is when the hint is meant to fire.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/services/4_infrastructure/favorites/coach_mark_service.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/favorites_page.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart';

import 'helpers/test_app.dart';
import 'helpers/mock_services.dart';

void main() {
  late TestServices services;
  late AuthProvider authProvider;
  late FavoritesProvider favorites;

  /// Advance in frames. The hint is a sequence of delays AND animations, so
  /// one long pump elapses the delays without ticking the controller.
  Future<void> advance(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Where the first card's content sits horizontally. Read from geometry,
  /// because geometry is what the user sees: the card is translated by an
  /// exact pixel count (ADR 0016), and a widget-property assertion would not
  /// notice a translation that never reaches the screen.
  double firstCardLeft(WidgetTester tester) => tester
      .getTopLeft(
        find
            .descendant(
              of: find.byType(FavoriteRiverCard).first,
              matching: find.byType(ClipRRect),
            )
            .first,
      )
      .dx;

  /// Builds the whole harness. MUST be called from `setUp`, never from
  /// inside `testWidgets`: the test body runs in Flutter's fake-async zone,
  /// where a real platform-channel future (SharedPreferences, the mock
  /// sign-in) never completes and the test hangs instead of failing. That is
  /// why every other favourites test in this directory does its setup in
  /// `setUp`, and why each scenario below is its own group.
  Future<void> setUpWith({required Map<String, Object> prefs}) async {
    SharedPreferences.setMockInitialValues(prefs);
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    FavoriteRiverCard.openRow.value = null;
    await resetServiceLocator();
    services = TestServices();
    services.seedSignedInUser();
    services.seedFavorites([
      for (var i = 0; i < 3; i++)
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
  }

  tearDown(() async {
    FavoriteRiverCard.openRow.value = null;
    await resetServiceLocator();
  });

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      buildTestApp(
        home: const FavoritesPage(),
        services: services,
        authProvider: authProvider,
        favoritesProvider: favorites,
        // Without this the harness overwrites the prefs this file seeds, and
        // every assertion below would watch a hint that was never going to
        // play. Two of these tests passed for exactly that wrong reason
        // before the flag existed.
        seedSwipeHintSeen: false,
      ),
    );
    // Let the list load. The page decides about the hint in a post-frame
    // callback AFTER the rivers arrive, because at first frame the list is
    // always empty.
    await advance(tester, 600);
  }

  group('the second arrival', () {
    // `favorites_visit_count: 1` makes this launch the SECOND arrival.
    setUp(
      () => setUpWith(
        prefs: {'has_seen_swipe_hint': false, 'favorites_visit_count': 1},
      ),
    );

    testWidgets('the first card really moves, then returns', (tester) async {
      await pumpList(tester);

      // Record the extremes across the whole window rather than diffing
      // against a "resting" value read at one moment. An earlier version
      // sampled resting AFTER the hint had already begun, so every later
      // sample looked like a return to rest and the measurement read zero
      // movement on a hint that was playing perfectly.
      var leftmost = double.infinity;
      var rightmost = -double.infinity;
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        final x = firstCardLeft(tester);
        if (x < leftmost) leftmost = x;
        if (x > rightmost) rightmost = x;
      }

      expect(
        rightmost - leftmost,
        greaterThan(40.0),
        reason:
            'the point of the hint is to SHOW the hidden actions by '
            'moving the real card. No movement means the page never asked a '
            'card to play it, and every source-grep guard still passes',
      );

      await advance(tester, 2000);
      expect(
        firstCardLeft(tester),
        closeTo(rightmost, 0.5),
        reason:
            'it must end back at rest; leaving the row stuck open would '
            'be worse than not hinting at all',
      );
    });
  });

  group('and it is marked seen, so it never plays twice', () {
    setUp(
      () => setUpWith(
        prefs: {'has_seen_swipe_hint': false, 'favorites_visit_count': 1},
      ),
    );

    testWidgets('and it is marked seen, so it never plays twice', (
      tester,
    ) async {
      await pumpList(tester);
      await advance(tester, 3000);

      expect(
        await CoachMarkService.hasSeenSwipeHint(),
        isTrue,
        reason:
            'the completion callback is the only place the once-ever rule '
            'is persisted. Without it a user who keeps the app gets the hint '
            'on every single visit',
      );
    });
  });

  group('on the FIRST arrival the card does not move', () {
    setUp(() => setUpWith(prefs: {'has_seen_swipe_hint': false}));

    testWidgets('on the FIRST arrival the card does not move', (tester) async {
      // The rule Jerson asked for, and the positive control for the test
      // above: a guard that only checks "the card moved" would be satisfied by
      // a hint that fires every time, which is the invasive behaviour the old
      // coach-mark tour was removed for.
      await pumpList(tester);

      final resting = firstCardLeft(tester);
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(
          firstCardLeft(tester),
          closeTo(resting, 0.5),
          reason:
              'the first arrival is the moment someone wants to look at '
              'the river they just saved',
        );
      }
      expect(
        await CoachMarkService.hasSeenSwipeHint(),
        isFalse,
        reason: 'and the one chance to show it must not be spent',
      );
    });
  });

  group('a user who has already seen it is left alone', () {
    setUp(
      () => setUpWith(
        prefs: {'has_seen_swipe_hint': true, 'favorites_visit_count': 9},
      ),
    );

    testWidgets('a user who has already seen it is left alone', (tester) async {
      await pumpList(tester);

      final resting = firstCardLeft(tester);
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(firstCardLeft(tester), closeTo(resting, 0.5));
      }
    });
  });
}
