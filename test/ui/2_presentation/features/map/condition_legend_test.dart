import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/condition_legend.dart';

Future<void> pumpLegend(WidgetTester tester, {String? dataDate}) async {
  await tester.pumpWidget(
    CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(child: ConditionLegend(dataDate: dataDate)),
      ),
    ),
  );
}

void main() {
  group('renders the date as a single "As of" line', () {
    testWidgets('formats month name and ordinal day', (tester) async {
      await pumpLegend(tester, dataDate: '2026-08-20');
      expect(find.text('As of August 20th'), findsOneWidget);
    });

    // The two lines this replaced. Neither should survive anywhere.
    testWidgets('drops the old two-line wording', (tester) async {
      await pumpLegend(tester, dataDate: '2026-08-20');
      expect(find.text('Peak risk in the days ahead'), findsNothing);
      expect(find.textContaining('Conditions from'), findsNothing);
    });

    testWidgets('st, nd, rd suffixes', (tester) async {
      await pumpLegend(tester, dataDate: '2026-03-01');
      expect(find.text('As of March 1st'), findsOneWidget);

      await pumpLegend(tester, dataDate: '2026-03-22');
      expect(find.text('As of March 22nd'), findsOneWidget);

      await pumpLegend(tester, dataDate: '2026-03-23');
      expect(find.text('As of March 23rd'), findsOneWidget);
    });

    // 11/12/13 end in 1/2/3 but take "th". The case a naive lookup table gets
    // wrong, and it only shows up three days a month.
    testWidgets('the teens all take th', (tester) async {
      for (final (day, want) in [(11, '11th'), (12, '12th'), (13, '13th')]) {
        await pumpLegend(tester, dataDate: '2026-03-${day.toString().padLeft(2, '0')}');
        expect(find.text('As of March $want'), findsOneWidget,
            reason: 'day $day');
      }
    });

    testWidgets('21st and 31st are not caught by the teens rule',
        (tester) async {
      await pumpLegend(tester, dataDate: '2026-03-21');
      expect(find.text('As of March 21st'), findsOneWidget);

      await pumpLegend(tester, dataDate: '2026-03-31');
      expect(find.text('As of March 31st'), findsOneWidget);
    });

    testWidgets('every month name spells out in full', (tester) async {
      const names = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December',
      ];
      for (var m = 1; m <= 12; m++) {
        await pumpLegend(
            tester, dataDate: '2026-${m.toString().padLeft(2, '0')}-05');
        expect(find.text('As of ${names[m - 1]} 5th'), findsOneWidget,
            reason: 'month $m');
      }
    });
  });

  group('says nothing rather than guessing', () {
    // The date comes from Remote Config, which can be slow, absent on first
    // launch, or offline. A legend with no date is honest; "As of null" or a
    // silently wrong date is not.
    testWidgets('no date supplied', (tester) async {
      await pumpLegend(tester);
      expect(find.textContaining('As of'), findsNothing);
    });

    testWidgets('empty string', (tester) async {
      await pumpLegend(tester, dataDate: '');
      expect(find.textContaining('As of'), findsNothing);
    });

    testWidgets('unparseable value', (tester) async {
      await pumpLegend(tester, dataDate: 'not-a-date');
      expect(find.textContaining('As of'), findsNothing);
    });
  });

  group('still a legend', () {
    testWidgets('shows the full ladder', (tester) async {
      await pumpLegend(tester, dataDate: '2026-08-20');
      for (final label in ['Normal', 'Action', 'Moderate', 'Major', 'Extreme']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('collapses on tap, hiding the date and the ladder',
        (tester) async {
      await pumpLegend(tester, dataDate: '2026-08-20');
      expect(find.text('As of August 20th'), findsOneWidget);

      await tester.tap(find.text('FLOOD RISK'));
      await tester.pumpAndSettle();

      expect(find.text('FLOOD RISK'), findsOneWidget);
      expect(find.text('As of August 20th'), findsNothing);
      expect(find.text('Extreme'), findsNothing);
    });
  });
}
