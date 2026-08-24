// test/services/0_config/shared/flood_palette_consumers_test.dart
//
// flood_palette_test.dart pins the SOURCE of truth — that AppConstants owns
// one colour per rung and that nothing off the ladder resolves to a real
// colour. It says nothing about whether any screen actually reads from it.
//
// That gap is the whole bug. ADR 0007 gave the palette one owner but its
// audit only covered daily_expandable_widget/, the map service and the
// legend; four more surfaces kept their own
// systemBlue/Yellow/Orange/Red/Purple copies. Every palette test passed the
// entire time, because none of them looked at a rendered pixel.
//
// So these tests assert the RENDERED colour of each consumer against the live
// constant — never against a hardcoded hex. That is what makes them a trap: a
// consumer reading a re-introduced local copy tracks the copy, so the moment
// AppConstants.floodCategoryColors is edited the consumer's test fails and
// names the file that stopped following.
//
// It also fails immediately today, without waiting for an edit, because the
// canonical ladder deliberately is NOT the Cupertino system colours
// (#FFC400 vs systemYellow #FFCC00, #E53935 vs systemRed, and so on). Any
// revert to the old literals is caught on the next run.
//
// The fourth consumer, reach_forecast_page.dart, is covered in its own file
// (test/ui/2_presentation/features/forecast/reach_forecast_page_test.dart) —
// it needs that file's repository/provider harness, which is not worth
// duplicating here.

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';

import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/2_usecases/features/favorites/add_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/initialize_favorites_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/remove_favorite_usecase.dart';
import 'package:rivr/models/2_usecases/features/favorites/reorder_favorites_usecase.dart';
import 'package:rivr/services/0_config/shared/constants.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/flood_categories_info_sheet.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/flow_gauge.dart';

// ── Fixtures ─────────────────────────────────────────────────────────────────

/// Thresholds in the display unit, so a flow can be placed in any rung by
/// inspection: below 100 = Normal, 100-200 = Action, … 400+ = Extreme.
const Map<int, double> _thresholds = {2: 100, 5: 200, 10: 300, 25: 400};

/// One flow per rung, index-aligned with [kFloodCategories]. Kept short so the
/// gauge's 54pt figure cannot overflow its 300pt box.
const List<double> _flowInRung = [50, 150, 250, 350, 500];

/// Real conversion, not identity. An identity stub hides a missing CMS→CFS
/// conversion — the same trap called out in reach_forecast_page_test.
class _StubUnit implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  String getDisplayUnit() => 'ft³/s';
  @override
  double convertFlow(double value, String from, String to) {
    if (from == to) return value;
    if (from == 'CMS' && to == 'CFS') return value * 35.3147;
    if (from == 'CFS' && to == 'CMS') return value / 35.3147;
    return value;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stubs standing in for every collaborator FavoritesProvider resolves through
/// GetIt, so constructing the provider touches no real service. The use cases
/// need one class each: they are callable objects whose `call` signatures
/// differ, so a single class cannot implement all four.
class _NoopDeps
    implements IFavoritesService, IReachCacheService, IRiverDataRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopInit implements InitializeFavoritesUseCase {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopAdd implements AddFavoriteUseCase {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopRemove implements RemoveFavoriteUseCase {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopReorder implements ReorderFavoritesUseCase {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// FavoritesProvider with the two reads the card makes stubbed out. Subclassed
/// rather than faked because the card does `context.read<FavoritesProvider>()`
/// on the concrete type.
class _FakeFavoritesProvider extends FavoritesProvider {
  _FakeFavoritesProvider(this._returnPeriods)
      : super(
          favoritesService: _NoopDeps(),
          reachCacheService: _NoopDeps(),
          unitService: _StubUnit(),
          initializeFavorites: _NoopInit(),
          addFavoriteUseCase: _NoopAdd(),
          removeFavoriteUseCase: _NoopRemove(),
          reorderFavoritesUseCase: _NoopReorder(),
          repository: _NoopDeps(),
        );

  final Map<int, double>? _returnPeriods;

  @override
  Map<int, double>? getReturnPeriods(String reachId) => _returnPeriods;
  @override
  bool isRefreshing(String reachId) => false;
}

Widget _app(Widget child) => CupertinoApp(home: child);

void main() {
  // ── FlowGauge ──────────────────────────────────────────────────────────────
  //
  // The gauge's category label is painted with markerColor, which is
  // zoneColors[i] — the same list the arc segments are drawn from. Asserting
  // the label therefore pins the whole zone palette through a public surface,
  // without reaching into the private _GaugePainter.
  group('FlowGauge paints its zones from the palette', () {
    Future<Color?> pumpAndReadLabel(WidgetTester tester, int rung) async {
      await tester.pumpWidget(_app(Center(
        child: SizedBox(
          width: 300,
          child: FlowGauge(
            currentFlow: _flowInRung[rung],
            returnPeriods: _thresholds,
            unit: 'ft³/s',
          ),
        ),
      )));
      final label = kFloodCategories[rung].toUpperCase();
      expect(find.text(label), findsOneWidget,
          reason: '$label should be the rendered category for '
              '${_flowInRung[rung]} against $_thresholds');
      return tester.widget<Text>(find.text(label)).style?.color;
    }

    for (var rung = 0; rung < kFloodCategories.length; rung++) {
      testWidgets('${kFloodCategories[rung]} comes from floodCategoryColors',
          (tester) async {
        expect(
          await pumpAndReadLabel(tester, rung),
          AppConstants.floodCategoryColors[rung],
          reason: 'the gauge is not reading rung $rung from the palette — '
              'check for a re-introduced local list in flow_gauge.dart',
        );
      });
    }

    // The specific regression: _dynZoneColors was the Cupertino system ladder.
    // Four of the five rungs differ from it, so a revert cannot hide.
    testWidgets('no rung is a Cupertino system colour', (tester) async {
      const oldCopy = [
        CupertinoColors.systemBlue,
        CupertinoColors.systemYellow,
        CupertinoColors.systemOrange,
        CupertinoColors.systemRed,
        CupertinoColors.systemPurple,
      ];
      for (var rung = 1; rung < kFloodCategories.length; rung++) {
        expect(await pumpAndReadLabel(tester, rung), isNot(oldCopy[rung]),
            reason: '${kFloodCategories[rung]} rendered the pre-ADR-0007 '
                'system colour — the local copy is back');
      }
    });

    testWidgets('an unclassifiable flow does not borrow a rung colour',
        (tester) async {
      await tester.pumpWidget(_app(Center(
        child: SizedBox(
          width: 300,
          child: FlowGauge(
            currentFlow: 120,
            returnPeriods: null, // no thresholds => no category
            unit: 'ft³/s',
          ),
        ),
      )));
      expect(find.text('NO FLOOD DATA'), findsOneWidget);
      final color = tester.widget<Text>(find.text('NO FLOOD DATA')).style?.color;
      for (final rung in AppConstants.floodCategoryColors) {
        expect(color, isNot(rung),
            reason: 'unknown must not look like a real category');
      }
    });
  });

  // ── FloodCategoriesInfoSheet ───────────────────────────────────────────────
  group('FloodCategoriesInfoSheet icons come from the palette', () {
    setUp(() {
      GetIt.instance.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
    });
    tearDown(() => GetIt.instance.reset());

    // Icon per rung, in ladder order, as the sheet declares them.
    const icons = [
      CupertinoIcons.checkmark_circle_fill,
      CupertinoIcons.exclamationmark_triangle,
      CupertinoIcons.exclamationmark_triangle_fill,
      CupertinoIcons.exclamationmark_octagon_fill,
      CupertinoIcons.xmark_octagon_fill,
    ];

    Future<void> pumpSheet(WidgetTester tester) => tester.pumpWidget(_app(
          const FloodCategoriesInfoSheet(returnPeriods: _thresholds),
        ));

    testWidgets('every rung icon matches its canonical colour', (tester) async {
      await pumpSheet(tester);
      for (var rung = 0; rung < kFloodCategories.length; rung++) {
        final name = kFloodCategories[rung];
        expect(
          tester.widget<Icon>(find.byIcon(icons[rung])).color,
          AppConstants.getFlowCategoryColor(name),
          reason: '"$name" icon is not resolving through '
              'AppConstants.getFlowCategoryColor',
        );
      }
    });

    // Called out explicitly in the commit: Normal's icon was a hardcoded
    // systemGrey that predated the ladder and was never reconciled. Grey is
    // the UNKNOWN colour, so a Normal row painted grey claimed "unclassified"
    // on a row whose whole job is to explain what Normal means.
    testWidgets('Normal is the canonical blue, not the unknown grey',
        (tester) async {
      await pumpSheet(tester);
      final normal = tester.widget<Icon>(find.byIcon(icons[0])).color;
      expect(normal, AppConstants.getFlowCategoryColor('normal'));
      expect(normal, isNot(AppConstants.unknownCategoryColor),
          reason: 'Normal must not reuse the unknown colour');
      expect(normal, isNot(CupertinoColors.systemGrey),
          reason: 'the pre-fix hardcoded grey is back');
    });
  });

  // ── FavoriteRiverCard ──────────────────────────────────────────────────────
  group('FavoriteRiverCard badge comes from the palette', () {
    setUp(() {
      GetIt.instance.registerSingleton<IFlowUnitPreferenceService>(_StubUnit());
    });
    tearDown(() => GetIt.instance.reset());

    /// Return periods as the provider holds them: natively CMS. ×35.3147 gives
    /// the CFS bands {353, 706, 1059, 1412}, so the flows below land in a
    /// known rung only if the card converts — an unconverted read classifies
    /// every one of them as Extreme and fails.
    const rpCms = {2: 10.0, 5: 20.0, 10: 30.0, 25: 40.0};

    Future<Color?> pumpAndReadBadge(
      WidgetTester tester,
      double flowCfs, {
      Map<int, double>? returnPeriods = rpCms,
      required String expectedCategory,
    }) async {
      await tester.pumpWidget(_app(
        ChangeNotifierProvider<FavoritesProvider>.value(
          value: _FakeFavoritesProvider(returnPeriods),
          child: Center(
            child: SizedBox(
              width: 320,
              height: 220,
              child: FavoriteRiverCard(
                favorite: FavoriteRiver(
                  reachId: '123',
                  riverName: 'Test River',
                  displayOrder: 0,
                  lastKnownFlow: flowCfs,
                  storedFlowUnit: 'CFS',
                  source: ForecastSource.nwm,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      final badge = expectedCategory.toUpperCase();
      expect(find.text(badge), findsOneWidget,
          reason: '$flowCfs CFS against $rpCms should read $badge');
      final container = tester.widget<Container>(
        find.ancestor(of: find.text(badge), matching: find.byType(Container)).first,
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    testWidgets('a classified flow uses getFlowCategoryColor', (tester) async {
      // 800 CFS sits between the 5-yr (706) and 10-yr (1059) bands.
      expect(
        await pumpAndReadBadge(tester, 800, expectedCategory: 'Moderate'),
        AppConstants.getFlowCategoryColor('Moderate'),
        reason: 'the badge is not resolving through the palette — check for a '
            're-introduced switch in favorite_river_card.dart',
      );
    });

    testWidgets('a normal flow is the canonical blue, not systemBlue',
        (tester) async {
      final color =
          await pumpAndReadBadge(tester, 200, expectedCategory: 'Normal');
      expect(color, AppConstants.getFlowCategoryColor('Normal'));
      expect(color, isNot(CupertinoColors.systemBlue),
          reason: 'the pre-fix literal is back');
    });

    testWidgets('an extreme flow is the canonical purple, not systemPurple',
        (tester) async {
      final color =
          await pumpAndReadBadge(tester, 2000, expectedCategory: 'Extreme');
      expect(color, AppConstants.getFlowCategoryColor('Extreme'));
      expect(color, isNot(CupertinoColors.systemPurple),
          reason: 'the pre-fix literal is back');
    });

    // The old switch had explicit 'nodata'/'unknown' arms. getFlowCategoryColor
    // has no such arms — it returns unknown for anything off the ladder — so
    // this pins that the behaviour survived the delegation.
    testWidgets('no return periods still renders the unknown grey',
        (tester) async {
      expect(
        await pumpAndReadBadge(tester, 800,
            returnPeriods: null, expectedCategory: 'NoData'),
        AppConstants.unknownCategoryColor,
        reason: 'an unclassifiable favorite must not borrow a rung colour',
      );
    });
  });

  // ── Source-level backstop ──────────────────────────────────────────────────
  //
  // The render tests above catch a local copy the moment it DIVERGES from the
  // canonical palette. They cannot catch a copy that is byte-identical to
  // today's hexes — that one passes until someone edits the palette, which is
  // exactly when the render tests fire.
  //
  // This closes the remaining window cheaply: each consumer must still name
  // the canonical API. It is a weak assertion on purpose — a pattern-matching
  // scanner for "a five-colour ladder" was tried and rejected, because
  // favorite_river_card legitimately holds a second category-ordered map
  // (_getGradientColorsForCategory, two-stop gradients) that no honest regex
  // separates from the flat ladder. False alarms there would train the next
  // person to delete this test.
  group('the delegation stays in the source', () {
    const consumers = <String, List<String>>{
      'lib/ui/2_presentation/features/forecast/widgets/flow_gauge.dart': [
        'AppConstants.floodCategoryColors',
      ],
      'lib/ui/2_presentation/features/forecast/pages/reach_forecast_page.dart': [
        'AppConstants.floodCategoryColors',
      ],
      'lib/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart':
          ['AppConstants.getFlowCategoryColor'],
      'lib/ui/2_presentation/features/forecast/widgets/flood_categories_info_sheet.dart':
          ['AppConstants.getFlowCategoryColor'],
    };

    consumers.forEach((path, required) {
      test('${path.split('/').last} still sources the palette', () {
        final file = File(path);
        expect(file.existsSync(), isTrue,
            reason: '$path moved — update this list rather than deleting it');
        final src = file.readAsStringSync();
        for (final token in required) {
          expect(src.contains(token), isTrue,
              reason: '$path no longer references $token; a local palette is '
                  'the likely replacement');
        }
      });
    });

    // The info sheet names all five rungs individually, so a partial revert
    // (one row back to a literal) is visible here as well as in the render
    // test above.
    test('flood_categories_info_sheet resolves all five rungs', () {
      final src = File(
        'lib/ui/2_presentation/features/forecast/widgets/'
        'flood_categories_info_sheet.dart',
      ).readAsStringSync();
      for (final name in kFloodCategories) {
        expect(
          src.contains("getFlowCategoryColor('${name.toLowerCase()}')"),
          isTrue,
          reason: 'the "$name" row is not resolving through the palette',
        );
      }
    });
  });
}
