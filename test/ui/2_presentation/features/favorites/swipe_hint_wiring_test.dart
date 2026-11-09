// test/ui/2_presentation/features/favorites/swipe_hint_wiring_test.dart
//
// The swipe hint replaced a four-panel `tutorial_coach_mark` tour that fired
// the moment a user saved their first river. `swipe_hint_test.dart` proves the
// card performs the gesture and reports back; `coach_mark_service_test.dart`
// proves the "second arrival, once ever" decision. Neither can notice that
// nothing CALLS either one.
//
// Three connections carry the whole feature, and each has a silent failure:
//
//   1. the page passes `runSwipeHint` to a card   → no hint ever plays
//   2. `didPopNext` resolves on arrival           → the SECOND visit is never
//                                                   noticed, because the page
//                                                   is not rebuilt on a pop
//   3. completion marks it seen                   → it replays on every visit
//
// **Source-level, and therefore weaker than a behavioural test.** This is a
// tripwire for DELETION, and nothing more. Measured 2026-11-09: wrap either
// `setState(() => _swipeHintCardIndex = 0)` or
// `CoachMarkService.completeSwipeHint()` in `if (false)` and this file, plus
// `swipe_hint_test.dart` and `coach_mark_service_test.dart`, all stay green
// while the feature is dead — because the string being grepped for is still
// on the line.
//
// The behavioural guard that catches those is
// `test/integration_test/swipe_hint_plays_test.dart`, which pumps the real
// page and watches the first card move. It is the one that matters; keep
// this file for the cheap deletion check and do not treat it as coverage.
// (The claim here that "no unit test pumps FavoritesPage" was true when it
// was written and is no longer.)
//
// Comments are stripped before matching, because a guard a comment can
// satisfy is not a guard; this repository learned that twice in one day on
// 2026-08-30.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source with `//` line comments and `///` doc comments removed.
String _code(String path) => File(path)
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// The body of a zero-argument member, from its signature to the closing
/// brace at member indentation.
String _body(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, greaterThan(-1), reason: 'missing: $signature');
  final end = src.indexOf('\n  }', start);
  expect(end, greaterThan(start), reason: 'could not bound: $signature');
  return src.substring(start, end);
}

void main() {
  const page =
      'lib/ui/2_presentation/features/favorites/pages/favorites_page.dart';

  test('the page asks a card to play the hint', () {
    final src = _code(page);

    expect(src.contains('runSwipeHint:'), isTrue,
        reason: 'the card only demonstrates the gesture when the page asks '
            'it to. Without this argument the feature is dead code and every '
            'other swipe-hint test still passes');
    expect(src.contains('onSwipeHintComplete:'), isTrue,
        reason: 'without the callback the page never learns the hint played, '
            'so it is never marked seen and plays again on every visit');
  });

  test('returning to the list counts as an arrival', () {
    // This is the user-visible rule: "the second time a user gets back to the
    // favourites page". The page is NOT rebuilt when the forecast page pops,
    // so initState cannot see the second arrival — didPopNext is the only
    // place it can be noticed.
    final body = _body(_code(page), 'void didPopNext()');

    expect(body.contains('_resolveSwipeHint()'), isTrue,
        reason: 'without this the hint can only ever fire on a cold launch, '
            'and the second-visit rule silently becomes a first-visit rule');
    expect(body.contains('_swipeHintResolved = false'), isTrue,
        reason: 'the per-arrival guard has to be cleared or the resolve above '
            'returns immediately');
  });

  test('playing the hint marks it seen', () {
    final body = _body(_code(page), 'void _onSwipeHintComplete()');

    expect(body.contains('CoachMarkService.completeSwipeHint()'), isTrue,
        reason: 'the once-ever part is persisted here and nowhere else — '
            'drop it and a user who keeps the app gets the hint forever');
  });

  test('the old coach-mark tour is gone, dependency and all', () {
    final lib = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    // Comments stripped: `coach_mark_service.dart` explains what it replaced,
    // and that prose names the package.
    final offenders = lib
        .where((f) => _code(f.path).contains('tutorial_coach_mark'))
        .map((f) => f.path)
        .toList();

    expect(offenders, isEmpty,
        reason: 'the tour is what Jerson asked to remove: a 90%-black '
            'overlay with hideSkip: true, four panels, on the first river '
            'ever saved');
    expect(File('pubspec.yaml').readAsStringSync().contains('tutorial_coach_mark'),
        isFalse,
        reason: 'leaving the package declared invites the tour back');
  });
}
