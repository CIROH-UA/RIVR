// test/ui/2_presentation/features/favorites/favorite_river_card_swipe_test.dart
//
// ADR 0016's swipe mechanics, guarded by driving real gestures at the real
// card for the first time.
//
// WHY THIS FILE EXISTS. A 2026-11-09 mutation audit found no widget test for
// `FavoriteRiverCard` at all and blamed four of its findings on that. I
// re-derived the gaps instead of trusting the list, by mutating the card and
// running the whole suite for each change. Five of nine mutations were caught
// by the existing tests. **Four survived all 1,502 of them:**
//
//   * the reveal is not clamped, so the card can be dragged off screen;
//   * a drag that STARTS on an already-open row forgets it was open, so
//     dragging it back snaps shut instead of following the finger;
//   * the fling direction inverts, so a flick left closes and a flick right
//     opens;
//   * the strip behind the card is a different width than the card travels,
//     which is the exact defect ADR 0016 was written to fix (the card used to
//     stop with 19-26 pt of the first button still underneath it).
//
// The existing `swipe_hint_test.dart` pumps this card but only ever drives
// the HINT, never a finger, which is why the drag maths was untouched.
//
// Gestures are driven with an explicit `TestGesture` rather than
// `tester.drag` wherever an assertion is about the state DURING a drag:
// `drag` presses, moves and releases in one call, so the snap-on-release
// logic runs before anything can be observed, and the clamp and the
// drag-origin are both mid-drag properties.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
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
import 'package:rivr/ui/2_presentation/features/favorites/widgets/components/slide_action_buttons.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/components/slide_action_constants.dart';
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
  const favourite = FavoriteRiver(
    reachId: '123',
    riverName: 'Test River',
    displayOrder: 0,
    lastKnownFlow: 100,
    storedFlowUnit: 'CFS',
    source: ForecastSource.nwm,
  );

  setUp(() {
    GetIt.I.registerSingleton<IRiverDataCache>(_StubCache());
    GetIt.I.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
    GetIt.I.registerSingleton<IGeocodingService>(_StubGeocoding());
    FavoriteRiverCard.openRow.value = null;
  });
  tearDown(() {
    FavoriteRiverCard.openRow.value = null;
    return GetIt.I.reset();
  });

  /// Where the card content sits, captured on the first read so every
  /// assertion is a displacement rather than an absolute screen position.
  double? resting;

  /// Advance a bounded number of frames.
  ///
  /// NOT `pumpAndSettle`: something on this card animates continuously (the
  /// background media), so settling never completes and the test times out
  /// instead of failing. `swipe_hint_test.dart` pumps in a loop for the same
  /// reason. 600 ms comfortably covers the slide, which is an `animateTo`
  /// with an ease-out curve.
  Future<void> settle(WidgetTester tester, [int ms = 600]) async {
    for (var elapsed = 0; elapsed < ms; elapsed += 20) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpCard(WidgetTester tester) async {
    resting = null;
    await tester.pumpWidget(
      CupertinoApp(
        home: ChangeNotifierProvider<FavoritesProvider>.value(
          value: _buildProvider(),
          child: Center(
            child: SizedBox(
              width: 390,
              height: 220,
              child: FavoriteRiverCard(favorite: favourite, onTap: () {}),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// How far left the card has travelled, in logical pixels. Read from
  /// geometry: the card is translated by an exact pixel count (ADR 0016) and
  /// geometry is what the user sees.
  double revealed(WidgetTester tester) {
    final left = tester
        .getTopLeft(
          find
              .descendant(
                of: find.byType(FavoriteRiverCard),
                matching: find.byType(ClipRRect),
              )
              .first,
        )
        .dx;
    resting ??= left;
    return resting! - left;
  }

  Finder card() => find.byType(FavoriteRiverCard);

  testWidgets('the reveal stops at the action strip, however far you drag',
      (tester) async {
    await pumpCard(tester);
    revealed(tester); // capture the resting position

    // Split, with a pump between: a single large `moveBy` straight after
    // the touch-down is not picked up by the horizontal drag recogniser, so
    // the card never moves and the assertion would pass for the wrong
    // reason. Measured while writing this.
    final gesture = await tester.startGesture(tester.getCenter(card()));
    await tester.pump();
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-570, 0));
    await tester.pump();

    expect(
      revealed(tester),
      closeTo(SlideActionConstants.totalActionWidth, 0.5),
      reason: 'unclamped, a long drag carries the card off the side of the '
          'screen. The reveal is capped at the strip because there is '
          'nothing behind the card past it',
    );

    await gesture.up();
    await settle(tester);
  });

  testWidgets('dragging an OPEN row back follows the finger from where it was',
      (tester) async {
    await pumpCard(tester);
    revealed(tester);

    // Open it and let it latch.
    await tester.drag(card(), const Offset(-260, 0));
    await settle(tester);
    expect(revealed(tester),
        closeTo(SlideActionConstants.totalActionWidth, 0.5));

    // Now drag it back by 100, and look BEFORE releasing.
    final gesture = await tester.startGesture(tester.getCenter(card()));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(70, 0));
    await tester.pump();

    // A range, not an exact figure: the drag recogniser absorbs the first
    // ~30 px of a gesture as touch slop before it reports anything, so the
    // reveal lands near 146 rather than 116 and the exact number is a
    // property of the framework's slop, not of this card. What the card owns
    // is that the row FOLLOWED the finger part of the way back instead of
    // jumping to one end. Treating an open row as closed makes `dragged`
    // negative, which clamps to 0 and snaps the row shut on the first pixel.
    expect(
      revealed(tester),
      inExclusiveRange(
        SlideActionConstants.totalActionWidth / 2,
        SlideActionConstants.totalActionWidth,
      ),
      reason: 'the drag has to start from where the row already is. Treating '
          'an open row as closed makes it snap shut on the first pixel of a '
          'drag instead of following the finger back',
    );

    await gesture.up();
    await settle(tester);
  });

  group('releasing decides by direction when fast, by distance when not', () {
    // Driven as a PURE FUNCTION, because no widget test can reach the
    // velocity branch. ⏱ MEASURED 2026-11-09: `DragEndDetails.velocity`
    // reads effectively zero under `flutter test` for every synthetic
    // release I could build — `tester.fling` at 40/50/60/80 px and
    // hand-built gestures at 3, 6 and 10 samples — so they all fall through
    // to the distance test. `tester.fling` was non-monotonic too, opening
    // the row at 50 px but not at 40, 60 or 80, so it is not a usable
    // instrument for this at all.
    //
    // Inverting the direction test left all 1,502 tests green, and this is
    // what now refuses it.

    test('a fast flick LEFT opens, however short it was', () {
      expect(
        FavoriteRiverCard.shouldLatchOpen(velocity: -900, revealed: 0.05),
        isTrue,
        reason: 'leftward reveals the actions; a flick is an instruction '
            'even when the finger barely moved',
      );
    });

    test('a fast flick RIGHT closes, however far it had opened', () {
      expect(
        FavoriteRiverCard.shouldLatchOpen(velocity: 900, revealed: 0.95),
        isFalse,
        reason: 'the inverted version of this made the gesture run backwards '
            'and nothing in the suite noticed',
      );
    });

    test('below the fling speed, distance alone decides', () {
      expect(FavoriteRiverCard.shouldLatchOpen(velocity: 0, revealed: 0.31),
          isTrue);
      expect(FavoriteRiverCard.shouldLatchOpen(velocity: 0, revealed: 0.29),
          isFalse);
      expect(
        FavoriteRiverCard.shouldLatchOpen(
          velocity: FavoriteRiverCard.flingVelocity - 1,
          revealed: 0.1,
        ),
        isFalse,
        reason: 'just under the fling speed must still be judged on '
            'distance, or the threshold is decorative',
      );
    });
  });

  testWidgets('a slow short drag springs back rather than latching open',
      (tester) async {
    // The positive control for the fling test above: without it, "a flick
    // left opens" would be satisfied by a card that opens on ANY leftward
    // movement, which is the twitchy behaviour the 30% threshold prevents.
    await pumpCard(tester);
    revealed(tester);

    final gesture = await tester.startGesture(tester.getCenter(card()));
    // 40 px is under 30% of 216. Moved in steps with time between them so
    // the release velocity stays below the 300 px/s fling threshold.
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(-10, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await settle(tester);

    expect(revealed(tester), closeTo(0.0, 0.5),
        reason: 'a short, slow drag is an accident, not an instruction');
  });

  testWidgets('the strip behind the card is exactly as wide as the card moves',
      (tester) async {
    // THE defect ADR 0016 exists for. The reveal used to be a fraction of the
    // SCREEN handed to a SlideTransition, which multiplies by the width of
    // its child, and the card is 38 pt narrower than the screen. The card
    // came to rest with 19-26 pt of the first button still underneath it.
    //
    // Asserted as a RELATIONSHIP, not as 216. One number owns both sides, so
    // a deliberate redesign moves them together and this still passes; what
    // it refuses is the two sides disagreeing, which is the bug.
    await pumpCard(tester);
    revealed(tester);

    await tester.drag(card(), const Offset(-400, 0));
    await settle(tester);

    final strip = tester.getSize(find.byType(SlideActionButtons));
    expect(
      revealed(tester),
      closeTo(strip.width, 0.5),
      reason: 'the card must uncover the buttons and nothing else. Any gap '
          'leaves a button clipped under the card, which is what shipped '
          'before ADR 0016',
    );
  });

  testWidgets('the strip is three equal buttons at the ADR 0016 width',
      (tester) async {
    // A design-value tripwire, and labelled as one: 3 x 72 = 216 is a choice
    // the ADR made, not a derived truth. The assertion above would still
    // pass if someone changed the constant, because both sides move
    // together, so this is what notices the UI being redesigned by accident.
    expect(SlideActionConstants.buttonCount, 3);
    expect(SlideActionConstants.buttonWidth, 72.0);
    expect(SlideActionConstants.totalActionWidth, 216.0);

    await pumpCard(tester);
    await tester.drag(card(), const Offset(-400, 0));
    await settle(tester);

    final buttons = find.descendant(
      of: find.byType(SlideActionButtons),
      matching: find.byType(CupertinoButton),
    );
    expect(buttons.evaluate().length, 3,
        reason: 'three actions are reachable behind the card');
  });
}
