import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_flow_tiles.dart';

// The map colours a river by its PEAK across the forecast window; the sheet
// leads with flow RIGHT NOW. The second tile is what reconciles them, so which
// of its four states it lands in is the load-bearing decision (ADR 0005).

PeakOutlook outlook({int? peak, String? now, bool loading = false}) =>
    peakOutlookFor(
      peakIndex: peak,
      currentCategory: now,
      isClassifying: loading,
    );

Future<void> pumpTiles(
  WidgetTester tester, {
  String flowText = '74.2 CFS',
  String? category = 'Normal',
  int? peakIndex,
  String horizon = 'Next 5 days',
  bool isClassifying = false,
}) async {
  await tester.pumpWidget(
    CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: SizedBox(
            width: 340,
            child: ReachFlowTiles(
              flowText: flowText,
              currentCategory: category,
              peakCategoryIndex: peakIndex,
              horizonLabel: horizon,
              isClassifying: isClassifying,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('peakOutlookFor', () {
    test('rising — the case the redesign exists for', () {
      expect(outlook(peak: 2, now: 'Normal'), PeakOutlook.rising);
      expect(outlook(peak: 4, now: 'Normal'), PeakOutlook.rising);
      expect(outlook(peak: 3, now: 'Action'), PeakOutlook.rising);
    });

    // Absence from the flood tileset is not missing data — the tileset only
    // holds reaches at or above their own 2-year return period, so a null
    // category IS the all-clear. Most rivers, most days.
    test('calm — normal now, nothing coming', () {
      expect(outlook(peak: null, now: 'Normal'), PeakOutlook.calm);
      expect(outlook(peak: 0, now: 'Normal'), PeakOutlook.calm);
    });

    // The dangerous mistake: a river already at Major, with no higher peak,
    // must never be told "no flooding expected".
    test('steady — already elevated and not climbing', () {
      expect(outlook(peak: null, now: 'Major'), PeakOutlook.steady);
      expect(outlook(peak: 1, now: 'Action'), PeakOutlook.steady);
      expect(outlook(peak: 2, now: 'Extreme'), PeakOutlook.steady);
    });

    test('unknown — refuses to guess', () {
      expect(outlook(peak: 2, now: 'Normal', loading: true),
          PeakOutlook.unknown);
      expect(outlook(peak: 2, now: null), PeakOutlook.unknown);
      expect(outlook(peak: 2, now: 'Unknown'), PeakOutlook.unknown);
      expect(outlook(peak: 2, now: 'Elevated'), PeakOutlook.unknown);
    });

    test('a category outside the ladder does not throw or mislead', () {
      // Treated as no colour, so a Normal river still reads calm.
      expect(outlook(peak: 99, now: 'Normal'), PeakOutlook.rising);
      expect(outlook(peak: -1, now: 'Normal'), PeakOutlook.calm);
    });
  });

  group('the calm river', () {
    testWidgets('says no flooding expected, with the real window',
        (tester) async {
      await pumpTiles(tester, category: 'Normal', peakIndex: null);
      expect(find.text('74.2'), findsOneWidget);
      expect(find.text('CFS'), findsOneWidget);
      expect(find.text('No flooding expected'), findsOneWidget);
      expect(find.text('next 5 days'), findsOneWidget);
    });

    testWidgets('uses the reach\'s own horizon, not a fixed number',
        (tester) async {
      // GEOGLOWS publishes 15 days; Hawaii and Puerto Rico only 48 hours.
      await pumpTiles(tester, horizon: 'Next 48 hours');
      expect(find.text('next 48 hours'), findsOneWidget);
    });

    testWidgets('marks now and peak together on the ladder', (tester) async {
      await pumpTiles(tester);
      expect(find.text('now & peak'), findsOneWidget);
      expect(find.text('now'), findsNothing);
    });
  });

  group('the rising river', () {
    testWidgets('names the category it is heading for', (tester) async {
      await pumpTiles(tester, category: 'Normal', peakIndex: 2);
      expect(find.text('Moderate'), findsOneWidget);
      expect(find.text('EXPECTED'), findsOneWidget);
      expect(find.text('No flooding expected'), findsNothing);
    });

    testWidgets('shows both current flow and current category', (tester) async {
      await pumpTiles(tester, category: 'Normal', peakIndex: 3);
      expect(find.text('74.2'), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
      expect(find.text('Major'), findsOneWidget);
    });

    testWidgets('ladder carries separate now and peak markers',
        (tester) async {
      await pumpTiles(tester, category: 'Normal', peakIndex: 2);
      expect(find.text('now'), findsOneWidget);
      expect(find.text('peak'), findsOneWidget);
      expect(find.text('now & peak'), findsNothing);
    });
  });

  group('the already-flooding river', () {
    testWidgets('never claims the all-clear', (tester) async {
      await pumpTiles(tester, flowText: '820 CFS', category: 'Major');
      expect(find.text('No flooding expected'), findsNothing);
      expect(find.text('PEAK'), findsOneWidget);
      // Named in both tiles: current chip and peak tile.
      expect(find.text('Major'), findsNWidgets(2));
    });
  });

  group('while loading', () {
    testWidgets('waits rather than asserting anything', (tester) async {
      await pumpTiles(tester, category: null, isClassifying: true);
      expect(find.text('No flooding expected'), findsNothing);
      expect(find.byType(CupertinoActivityIndicator), findsWidgets);
      // Ladder is withheld too — it would have to pick a rung to point at.
      expect(find.text('now'), findsNothing);
      expect(find.text('now & peak'), findsNothing);
    });
  });

  group('flow formatting', () {
    testWidgets('splits value from unit without reformatting', (tester) async {
      await pumpTiles(tester, flowText: '57.1K CFS');
      expect(find.text('57.1K'), findsOneWidget);
      expect(find.text('CFS'), findsOneWidget);
    });

    testWidgets('survives a value with no unit', (tester) async {
      await pumpTiles(tester, flowText: '74.2');
      expect(find.text('74.2'), findsOneWidget);
    });

    testWidgets('handles CMS as readily as CFS', (tester) async {
      await pumpTiles(tester, flowText: '2.1 CMS');
      expect(find.text('2.1'), findsOneWidget);
      expect(find.text('CMS'), findsOneWidget);
    });
  });
}
