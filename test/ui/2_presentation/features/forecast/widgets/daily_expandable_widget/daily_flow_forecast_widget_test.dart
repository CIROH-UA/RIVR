// test/ui/2_presentation/features/forecast/widgets/daily_expandable_widget/
// daily_flow_forecast_widget_test.dart
//
// JAWRA R2-7: while the medium-range forecast was still loading (~4-5s), the
// app showed the same "No Forecast Data" card a river with genuinely no
// forecast gets. A slow load and an empty river were pixel-identical.
//
// The widget itself is only half of that story. It renders empty whenever its
// processed list is empty, which is correct and stays correct — deciding
// whether "empty" is even a meaningful answer yet belongs to the caller, and
// reach_forecast_page now gates on getSectionState('medium_range').isDone
// before mounting this widget at all.
//
// So this file pins the widget's half: that the empty card appears only for a
// genuinely empty response, and that a populated response renders rows
// instead. The loading-vs-empty gate itself is pinned in
// reach_forecast_page_test.dart, which already has the repository/provider
// harness needed to drive a real in-flight window.
//
// Before this file the widget had no test coverage at all.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/daily_expandable_widget/daily_flow_forecast_widget.dart';
import 'package:rivr/ui/2_presentation/features/forecast/widgets/daily_expandable_widget/daily_forecast_row.dart';

import '../../../../../../helpers/fake_data.dart';
import '../../../../../../helpers/test_helpers.dart';

/// Hourly points spanning [hours] from [startUtc], so the processor has
/// something to fold into day summaries.
ForecastSeries _series(DateTime startUtc, int hours) {
  return ForecastSeries(
    referenceTime: startUtc,
    units: 'CFS',
    data: [
      for (var i = 0; i < hours; i++)
        ForecastPoint(
          validTime: startUtc.add(Duration(hours: i)),
          flow: 100.0 + i * 5,
        ),
    ],
  );
}

ForecastResponse _response({required Map<String, ForecastSeries> mediumRange}) {
  return ForecastResponse(
    reach: createTestReachData(),
    mediumRange: mediumRange,
    longRange: const {},
  );
}

/// Pump the widget with enough height that its rows are not clipped away
/// before the finders run.
Future<void> _pump(WidgetTester tester, ForecastResponse? response) async {
  await tester.pumpWidget(CupertinoApp(
    home: CupertinoPageScaffold(
      child: SizedBox(
        height: 900,
        child: DailyFlowForecastWidget(
          forecastResponse: response,
          forecastType: 'medium_range',
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  setUp(setupTestServiceLocator);
  tearDown(tearDownServiceLocator);

  group('a genuinely empty response says so', () {
    testWidgets('no medium-range series shows the No Forecast Data card',
        (tester) async {
      await _pump(tester, _response(mediumRange: const {}));

      expect(find.text('No Forecast Data'), findsOneWidget);
      expect(find.byType(DailyForecastRow), findsNothing);
    });

    testWidgets('a series with no points shows the No Forecast Data card',
        (tester) async {
      final empty = ForecastSeries(
        referenceTime: DateTime.utc(2026, 8, 24, 12),
        units: 'CFS',
        data: const [],
      );
      await _pump(tester, _response(mediumRange: {'mean': empty}));

      expect(find.text('No Forecast Data'), findsOneWidget);
      expect(find.byType(DailyForecastRow), findsNothing);
    });

    // Checked rather than assumed: a null response is NOT folded into the
    // empty card. _processData treats it as an error, so it renders "Error
    // Loading Data" instead. That is a third distinct state, and pinning it
    // here keeps a future refactor from quietly collapsing it into "empty" —
    // which would recreate R2-7's problem in a new place.
    testWidgets('a null response is an error, not the empty card',
        (tester) async {
      await _pump(tester, null);

      expect(find.text('Error Loading Data'), findsOneWidget);
      expect(find.text('No forecast data available'), findsOneWidget);
      expect(find.text('No Forecast Data'), findsNothing,
          reason: 'null is a different condition from an empty series');
      expect(find.byType(DailyForecastRow), findsNothing);
    });
  });

  group('a populated response renders the forecast', () {
    testWidgets('rows appear and the empty card does not', (tester) async {
      // Three days of hourly points, anchored so the day boundaries are
      // deterministic regardless of when the test runs.
      await _pump(
        tester,
        _response(mediumRange: {
          'mean': _series(DateTime.utc(2026, 8, 24, 0), 72),
        }),
      );

      expect(find.byType(DailyForecastRow), findsWidgets,
          reason: 'a response with three days of points must render rows');
      expect(find.text('No Forecast Data'), findsNothing,
          reason: 'the empty card must never coexist with real forecast rows');
    });

    // The R2-7 defect in one assertion, at this widget's own level: whatever
    // the loaded state looks like, it must not be the empty state. If these
    // two ever render the same thing again, this fails.
    testWidgets('loaded and empty do not render the same thing',
        (tester) async {
      await _pump(
        tester,
        _response(mediumRange: {
          'mean': _series(DateTime.utc(2026, 8, 24, 0), 72),
        }),
      );
      final loadedHasEmptyCard = find.text('No Forecast Data').evaluate().isNotEmpty;
      final loadedRowCount = find.byType(DailyForecastRow).evaluate().length;

      await _pump(tester, _response(mediumRange: const {}));
      final emptyHasEmptyCard = find.text('No Forecast Data').evaluate().isNotEmpty;
      final emptyRowCount = find.byType(DailyForecastRow).evaluate().length;

      expect(loadedHasEmptyCard, isFalse);
      expect(emptyHasEmptyCard, isTrue);
      expect(loadedRowCount, greaterThan(emptyRowCount));
    });
  });
}
