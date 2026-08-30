// test/utils/startup_trace_wiring_test.dart
//
// ADR 0011 Phase 8 guard 2 — a guard on the WIRING, not the instrument.
//
// `startup_trace_test.dart` proves the stopwatch behaves. It cannot notice
// that nothing CALLS it. Delete `StartupTrace.begin()` from main, or the
// `markFavouritesRendered` post-frame callback from the favourites page, and
// every one of those tests still passes — the app simply stops producing the
// number this phase reports, silently.
//
// That is the same shape as every other defect found this week: the double
// unit conversion, the unmounted offline banner, the health check that was
// never fed, the dropped runId projection, the discarded server fetchedAt.
// The logic was tested; the connection to it was not.
//
// Source-level and therefore weaker than a behavioural test. There is no
// widget test that pumps FavoritesPage — it needs the full provider and GetIt
// graph — so this is a tripwire for deletion, not coverage. Mutation-checked
// both ways.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('the startup trace is actually wired up', () {
    test('main() starts the clock', () {
      final main = _read('lib/main.dart');
      expect(main.contains('StartupTrace.begin()'), isTrue,
          reason: 'without this the stopwatch never runs and '
              'markFavouritesRendered silently does nothing — the phase '
              'reports no number at all');
    });

    test('the clock starts BEFORE Flutter initialises', () {
      // The figure is meant to include everything a person waits through.
      // Starting it after ensureInitialized() would quietly exclude engine
      // startup and flatter the result.
      final main = _read('lib/main.dart');
      final begin = main.indexOf('StartupTrace.begin()');
      final ensure = main.indexOf('WidgetsFlutterBinding.ensureInitialized()');
      expect(begin, greaterThan(-1));
      expect(ensure, greaterThan(-1));
      expect(begin, lessThan(ensure),
          reason: 'the measurement must include engine startup, or it is not '
              'the number the guard asks for');
    });

    test('the favourites page marks the first render', () {
      final page = _read(
          'lib/ui/2_presentation/features/favorites/pages/favorites_page.dart');
      expect(page.contains('StartupTrace.markFavouritesRendered'), isTrue,
          reason: 'the mark is what ends the measurement; without it the '
              'stopwatch runs forever and nothing is ever reported');
      expect(page.contains('addPostFrameCallback'), isTrue,
          reason: 'marking during build measures the frame that has not '
              'painted yet, which is not what "rendered" means');
    });

    // The stdout copy must NOT ship. `debugPrint` is not stripped in release —
    // Flutter's own docs say it "logs to console even in release mode", and
    // `strings` on the built IPA confirmed the literal was present in
    // 2026.2.0+719. Its whole justification is that `flutter run` does not
    // forward `dart:developer`, and `flutter run` never applies to a release
    // build.
    //
    // Source-level, and deliberately so: `kReleaseMode` is a compile-time
    // constant that is false under `flutter test`, so no test can exercise the
    // release branch. This is a tripwire against the guard being dropped, not
    // coverage of it.
    test('the stdout trace is guarded against release builds', () {
      final src = _read('lib/utils/startup_trace.dart');
      expect(src.contains('if (!kReleaseMode) debugPrint('), isTrue,
          reason: 'without this every user gets a console line per launch — '
              'harmless in content, wrong by default, and inconsistent with '
              'AppLogger, which gates its debug and info levels the same way');
    });

    // Both source branches must settle the flow, not just NWM.
    //
    // The third Phase 8 review found `_flowSettled` set only in the NWM
    // branch, so on a GEOGLOWS reach the "current flow is not available" strip
    // could never appear — a global river that decoded to no points showed a
    // blank gauge and said nothing about why. Narrow to reach, but a real
    // behaviour change from the `!_loading` gate it replaced.
    test('both load paths settle the flow flag', () {
      final page = _read(
          'lib/ui/2_presentation/features/forecast/pages/reach_forecast_page.dart');

      // COUNTING was not enough, and round 4 proved it: removing the GEOGLOWS
      // settle and adding a redundant one in the NWM branch — the exact
      // round-3 defect, restored — kept the count at three and this test
      // passed. So it checks WHERE the settles are, not how many.
      final geoStart = page.indexOf('Future<void> _loadGeoglows()');
      expect(geoStart, greaterThan(-1),
          reason: '_loadGeoglows is gone or renamed; this guard must follow '
              'it rather than silently passing');
      // Bounded to the METHOD by matching braces, not to end-of-file.
      //
      // `substring(geoStart)` ran to EOF, so it counted settles in anything
      // defined after `_loadGeoglows` — the failure message said "inside
      // _loadGeoglows" and it was not. Round 5 defeated it that way. A first
      // attempt at the bound looked for the next `\n  Future<`, which is also
      // wrong here: the next member is a getter, so it found nothing and ran
      // to EOF all over again. Braces cannot be fooled by what kind of member
      // comes next.
      var depth = 0;
      var geoEnd = page.length;
      var seenOpen = false;
      for (var i = geoStart; i < page.length; i++) {
        final ch = page[i];
        if (ch == '{') {
          depth++;
          seenOpen = true;
        } else if (ch == '}') {
          depth--;
          if (seenOpen && depth == 0) {
            geoEnd = i + 1;
            break;
          }
        }
      }
      final geoBody = page.substring(geoStart, geoEnd);

      final inGeoglows = '_flowSettled = true'.allMatches(geoBody).length;
      expect(inGeoglows, greaterThanOrEqualTo(2),
          reason: 'both GEOGLOWS outcomes — the successful decode and the '
              'caught error — must settle the flag, or a global river that '
              'decodes to no points shows a blank gauge and says nothing '
              'about why. Found $inGeoglows inside _loadGeoglows.');

      final beforeGeo = page.substring(0, geoStart);
      expect('_flowSettled = true'.allMatches(beforeGeo).length,
          greaterThanOrEqualTo(1),
          reason: 'the NWM read must settle it too');
    });
  });
}
