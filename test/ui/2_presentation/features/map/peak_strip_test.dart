import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/ui/2_presentation/features/map/widgets/reach_details_bottom_sheet.dart';

// The map colours a river by its PEAK across the forecast window; the sheet
// leads with flow RIGHT NOW. An orange river that reads "Normal" on tap is
// correct and looks exactly like a bug, which is the whole reason this strip
// exists (ADR 0005). These cases pin when it speaks and when it stays quiet.

bool show({
  int? peak,
  String? current,
  bool loading = false,
}) =>
    shouldShowPeakStrip(
      peakIndex: peak,
      currentCategory: current,
      isClassifying: loading,
    );

void main() {
  group('speaks when the peak outranks now', () {
    test('the case that prompted this — orange line, Normal flow', () {
      expect(show(peak: 2, current: 'Normal'), isTrue);
    });

    test('every step above the current category', () {
      expect(show(peak: 1, current: 'Normal'), isTrue);
      expect(show(peak: 4, current: 'Normal'), isTrue);
      expect(show(peak: 3, current: 'Action'), isTrue);
      expect(show(peak: 4, current: 'Major'), isTrue);
    });
  });

  group('stays quiet when there is nothing to reconcile', () {
    test('the river is already flowing at the mapped category', () {
      expect(show(peak: 2, current: 'Moderate'), isFalse);
      expect(show(peak: 4, current: 'Extreme'), isFalse);
    });

    // The sheet fetches live; the tileset was built at 11:00 UTC. When flow has
    // outrun the map the sheet is the newer source and is right — apologising
    // for the map on every such tap would be noise.
    test('current flow has outrun the map', () {
      expect(show(peak: 1, current: 'Major'), isFalse);
      expect(show(peak: 2, current: 'Extreme'), isFalse);
    });

    test('the map is not colouring this river at all', () {
      expect(show(peak: null, current: 'Normal'), isFalse);
    });

    // 0 is 'Normal'. The tileset never emits it — reaches below the 2-year
    // gate are not written — but a strip reading "Forecast peak: Normal"
    // would explain nothing if it ever did.
    test('category 0 is not a peak', () {
      expect(show(peak: 0, current: 'Normal'), isFalse);
    });
  });

  group('refuses to guess', () {
    test('silent while classification is still loading', () {
      // Same inputs that would otherwise show — a strip that appears then
      // changes its mind reads as a glitch.
      expect(show(peak: 3, current: 'Normal', loading: true), isFalse);
      expect(show(peak: 3, current: 'Normal', loading: false), isTrue);
    });

    test('silent before current flow is known', () {
      expect(show(peak: 3, current: null), isFalse);
    });

    test('silent when current flow could not be classified', () {
      // FlowClassification.category() returns this when return periods are
      // missing — common for reaches with no thresholds published.
      expect(show(peak: 3, current: 'Unknown'), isFalse);
    });

    test('silent on a category outside the ladder', () {
      // A future tileset growing a 5th category must not crash or index past
      // the end of kFloodCategories.
      expect(show(peak: 5, current: 'Normal'), isFalse);
      expect(show(peak: 99, current: 'Normal'), isFalse);
      expect(show(peak: -1, current: 'Normal'), isFalse);
    });

    test('silent on a category name the ladder does not contain', () {
      expect(show(peak: 3, current: 'Elevated'), isFalse);
      expect(show(peak: 3, current: ''), isFalse);
    });
  });
}
