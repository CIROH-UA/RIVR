import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_details_disclosure.dart';

const _rows = [
  DetailRow('Reach ID', '10376596'),
  DetailRow('Stream order', '5'),
  DetailRow('Coordinates', '40.233800, -111.658500'),
  DetailRow('Forecast window', 'Next 5 days'),
  DetailRow('Source', 'NOAA NWM'),
];

Future<void> pump(
  WidgetTester tester, {
  List<DetailRow> rows = _rows,
  List<DetailRow> thresholds = const [],
  bool expanded = false,
}) async {
  await tester.pumpWidget(
    CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: SizedBox(
            width: 340,
            child: ReachDetailsDisclosure(
              rows: rows,
              thresholds: thresholds,
              initiallyExpanded: expanded,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // These identifiers used to sit above current flow at equal weight, so the
  // sheet answered "which reach is this" before "is the river high". They are
  // demoted, not deleted — the NWM and GEOGLOWS teams read them.
  testWidgets('starts collapsed, showing only the control', (tester) async {
    await pump(tester);
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('10376596'), findsNothing);
    expect(find.text('Stream order'), findsNothing);
  });

  testWidgets('reveals every row on tap', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    for (final r in _rows) {
      expect(find.text(r.label), findsOneWidget, reason: r.label);
      expect(find.text(r.value), findsOneWidget, reason: r.value);
    }
  });

  testWidgets('collapses again on a second tap', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('10376596'), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('10376596'), findsNothing);
  });

  testWidgets('the whole row is the target, not just the word', (tester) async {
    await pump(tester);
    // Tap the chevron end of the row.
    final box = tester.getRect(find.byType(ReachDetailsDisclosure));
    await tester.tapAt(Offset(box.right - 20, box.top + 20));
    await tester.pumpAndSettle();
    expect(find.text('10376596'), findsOneWidget);
  });

  testWidgets('thresholds get their own labelled group when supplied',
      (tester) async {
    await pump(
      tester,
      thresholds: const [DetailRow('2-year', '180 CFS')],
      expanded: true,
    );
    expect(find.text('FLOOD THRESHOLDS'), findsOneWidget);
    expect(find.text('2-year'), findsOneWidget);
  });

  testWidgets('no threshold heading when there are none', (tester) async {
    await pump(tester, expanded: true);
    expect(find.text('FLOOD THRESHOLDS'), findsNothing);
  });

  // A reach with no geocoded location passes fewer rows; the widget must not
  // assume a fixed set.
  testWidgets('renders a short row list', (tester) async {
    await pump(
      tester,
      rows: const [DetailRow('Reach ID', '99')],
      expanded: true,
    );
    expect(find.text('99'), findsOneWidget);
  });
}
