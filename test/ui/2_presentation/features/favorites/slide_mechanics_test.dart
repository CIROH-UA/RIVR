// test/ui/2_presentation/features/favorites/slide_mechanics_test.dart
//
// ADR 0016. Jerson: "the card slide has something that does not make it look
// professional or smooth and I don't know what it is."
//
// It was two numbers. The card was translated by a fraction computed against
// the SCREEN's width and applied to the CARD, which is 38 pt narrower, so it
// tracked the finger at 91% and came to rest with 19-26 pt of the first
// action button still underneath it. These guards are in pixels, because
// pixels are what went wrong.

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

  const favourite = FavoriteRiver(
    reachId: '123',
    riverName: 'Test River',
    displayOrder: 0,
    lastKnownFlow: 100,
    storedFlowUnit: 'CFS',
    source: ForecastSource.nwm,
  );

  /// A card at real iPhone metrics, filling the width the way the list does.
  Future<void> pumpCard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556); // iPhone 16 Pro
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(CupertinoApp(
      home: ChangeNotifierProvider<FavoritesProvider>.value(
        value: _buildProvider(),
        child: const Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: 240,
            child: FavoriteRiverCard(favorite: favourite),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// `pumpAndSettle` never returns here — the card runs a looping video, so
  /// a frame is always scheduled. Pump a fixed stretch instead.
  Future<void> settle(WidgetTester tester, [int ms = 600]) async {
    for (var i = 0; i < ms ~/ 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Finder cardContent() => find.descendant(
        of: find.byType(FavoriteRiverCard),
        matching: find.byType(ClipRRect),
      );

  testWidgets('the card follows the finger one for one', (tester) async {
    await pumpCard(tester);
    final start = tester.getTopLeft(cardContent()).dx;

    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(FavoriteRiverCard)));
    await tester.pump();

    // Past the recogniser's slop, then a round number of pixels.
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    final afterSlop = tester.getTopLeft(cardContent()).dx;

    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    final after100 = tester.getTopLeft(cardContent()).dx;

    expect(afterSlop - after100, closeTo(100, 0.5),
        reason: 'the card must move exactly as far as the finger does. It '
            'used to move 91 pt for every 100 — a fraction of the screen '
            'applied to a narrower card');

    await gesture.up();
    await settle(tester);
    expect(tester.getTopLeft(cardContent()).dx, lessThan(start));
  });

  testWidgets('fully open uncovers the whole action strip, exactly',
      (tester) async {
    await pumpCard(tester);
    final closed = tester.getTopLeft(cardContent()).dx;

    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(FavoriteRiverCard)));
    await tester.pump();
    await gesture.moveBy(const Offset(-260, 0)); // past full
    await tester.pump();
    await gesture.up();
    await settle(tester);

    final travelled = closed - tester.getTopLeft(cardContent()).dx;
    expect(travelled, closeTo(SlideActionConstants.totalActionWidth, 0.5),
        reason: 'the card has to clear the buttons completely. It used to '
            'stop 19-26 pt short, leaving the first button clipped');

    // And the strip really is that wide, so "cleared" means what it says.
    expect(tester.getSize(find.byType(SlideActionButtons)).width,
        SlideActionConstants.totalActionWidth);
  });

  testWidgets('the buttons are uncovered, not popped in', (tester) async {
    await pumpCard(tester);
    expect(find.byType(SlideActionButtons), findsNothing,
        reason: 'nothing behind a closed card');

    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(FavoriteRiverCard)));
    await tester.pump();
    await gesture.moveBy(const Offset(-25, 0)); // barely past slop
    await tester.pump();

    expect(find.byType(SlideActionButtons), findsOneWidget,
        reason: 'the buttons must exist from the first pixel of movement so '
            'the card UNCOVERS them. They used to be mounted only once the '
            'row counted as open, appearing in a single frame');

    await gesture.up();
    await settle(tester);
  });

  testWidgets('a tap on an open row closes it instead of doing nothing',
      (tester) async {
    await pumpCard(tester);
    final closed = tester.getTopLeft(cardContent()).dx;

    await tester.drag(
        find.byType(FavoriteRiverCard), const Offset(-260, 0));
    await settle(tester);
    expect(tester.getTopLeft(cardContent()).dx, lessThan(closed));

    // Tap the part of the card still on screen.
    await tester.tapAt(const Offset(60, 80));
    await settle(tester);

    expect(tester.getTopLeft(cardContent()).dx, closeTo(closed, 0.5),
        reason: 'the tap used to be swallowed, which looks like a freeze');
  });

  testWidgets('the open card meets the buttons flush, with no white notch',
      (tester) async {
    // Reported by Jerson from a screenshot, 2026-11-02: with the row open,
    // the card's rounded top-right and bottom-right corners sat against the
    // flat left edge of the blue button and the page showed through as two
    // white wedges.
    BorderRadius cardShape() => (tester.widget<ClipRRect>(find.descendant(
          of: find.byType(FavoriteRiverCard),
          matching: find.byType(ClipRRect),
        )).borderRadius as BorderRadius);

    await pumpCard(tester);

    expect(cardShape().topRight.x, greaterThan(0),
        reason: 'closed, the card sits on the page and is a rounded card');

    await tester.drag(find.byType(FavoriteRiverCard), const Offset(-260, 0));
    await settle(tester);

    expect(cardShape().topRight.x, 0,
        reason: 'open, the right edge butts against the blue button — a '
            'rounded corner there shows the page through as a notch');
    expect(cardShape().bottomRight.x, 0);
    expect(cardShape().topLeft.x, greaterThan(0),
        reason: 'the left edge is still a card edge, and slides off screen');
  });

  testWidgets('the row does not shrink while being dragged', (tester) async {
    await pumpCard(tester);
    // getRect, not getSize: a scale transform leaves the layout size alone
    // and only shows up once the rect is projected to screen space. Using
    // getSize here made this guard vacuous — it passed with the squeeze
    // still in place.
    final restingWidth = tester.getRect(cardContent()).width;

    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(FavoriteRiverCard)));
    await tester.pump();
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.getRect(cardContent()).width, closeTo(restingWidth, 0.01),
        reason: 'grabbing the row used to scale it to 98%, so it wobbled '
            'under the finger on top of sliding');

    await gesture.up();
    await settle(tester);
  });
}
