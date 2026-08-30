// test/utils/startup_trace_test.dart
//
// ADR 0011 Phase 8 guard 2. The instrument that produces the phase's headline
// number, so it needs to be right for the same reason the number does.
//
// The failure that matters is not the stopwatch being slightly off — it is the
// mark being taken on the WRONG frame. Favourites rebuild constantly (every
// refresh, every unit change, every scroll that changes a card); if the mark
// were taken on the latest one, the "cold start" figure would quietly become
// "time since the most recent rebuild", which is a small number that always
// passes and means nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/utils/startup_trace.dart';

void main() {
  setUp(StartupTrace.resetForTest);
  tearDown(StartupTrace.resetForTest);

  test('reports nothing before begin()', () {
    expect(StartupTrace.elapsedMs, isNull);
  });

  test('measures from begin()', () async {
    StartupTrace.begin();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(StartupTrace.elapsedMs, isNotNull);
    expect(StartupTrace.elapsedMs, greaterThanOrEqualTo(15));
  });

  // THE property. Everything else here is bookkeeping.
  test('the mark is one-shot: later frames cannot overwrite it', () async {
    StartupTrace.begin();
    expect(StartupTrace.hasMarkedForTest, isFalse);

    StartupTrace.markFavouritesRendered(3);
    expect(StartupTrace.hasMarkedForTest, isTrue);

    final first = StartupTrace.favouritesRenderedAtMs;
    expect(first, isNotNull);

    // A favourites list rebuilds many times a session. If any of these
    // replaced the first mark, the number would stop being a cold-start
    // measurement and start being noise that always looks good.
    //
    // Asserting on the flag alone was NOT enough — mutation-checked: removing
    // the one-shot guard left the flag true and every assertion green while
    // the recorded VALUE was being overwritten on every frame.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    StartupTrace.markFavouritesRendered(3);
    StartupTrace.markFavouritesRendered(4);

    expect(StartupTrace.favouritesRenderedAtMs, first,
        reason: 'a later rebuild overwrote the cold-start figure');
  });

  test('marking without begin() does nothing rather than reporting zero', () {
    // A zero would look like a spectacular result and be meaningless.
    StartupTrace.markFavouritesRendered(2);
    expect(StartupTrace.hasMarkedForTest, isFalse);
    expect(StartupTrace.favouritesRenderedAtMs, isNull);
  });

  test('begin() clears a previous launch mark', () {
    StartupTrace.begin();
    StartupTrace.markFavouritesRendered(1);
    expect(StartupTrace.hasMarkedForTest, isTrue);

    StartupTrace.begin();
    expect(StartupTrace.hasMarkedForTest, isFalse,
        reason: 'a hot restart must be able to take a fresh measurement');
  });
}
