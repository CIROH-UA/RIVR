// lib/utils/startup_trace.dart
//
// ADR 0011 Phase 8 guard 2: "Favourites render under 3 s cold."
//
// **There was no instrumentation at all.** Every latency figure in ADR 0011 up
// to this point measured UPSTREAM — how long NOAA took to answer a probe — and
// none measured the thing the phase is actually about, which is how long a
// person waits for their rivers to appear. Phase 8 guard 8 asks for numbers
// recorded with the build they came from, and there was nothing to record.
//
// This is deliberately the smallest instrument that answers the guard: one
// stopwatch started as the app starts, one mark when the favourites list first
// paints with real content. It logs once per launch and then costs nothing.
//
// **What it measures, precisely**, because a number without its definition is
// how the Phase 0 table came to be optimistic: wall-clock from the first line
// of `main()` to the end of the first frame in which the favourites list is
// built with at least one favourite and `isLoading` false. It therefore
// includes Firebase init, auth restore, provider construction, the cache read
// and layout — everything the user waits through — and excludes only whatever
// the OS did before Dart started.

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Startup timing for the current launch.
class StartupTrace {
  StartupTrace._();

  static final Stopwatch _sinceStart = Stopwatch();
  static bool _favouritesMarked = false;
  static int? _favouritesAtMs;

  /// Called first thing in `main()`.
  static void begin() {
    _favouritesMarked = false;
    _favouritesAtMs = null;
    _sinceStart
      ..reset()
      ..start();
  }

  /// Milliseconds since [begin], or null if it was never called.
  static int? get elapsedMs =>
      _sinceStart.isRunning ? _sinceStart.elapsedMilliseconds : null;

  /// Called from a post-frame callback the first time the favourites list
  /// paints with content. Ignored on every later frame, so the number is
  /// "cold start to first useful paint" and not "most recent rebuild".
  ///
  /// [favouriteCount] is recorded with it because the figure is meaningless
  /// without it — three rivers and thirty are not the same measurement.
  static void markFavouritesRendered(int favouriteCount) {
    if (_favouritesMarked || !_sinceStart.isRunning) return;
    _favouritesMarked = true;
    final ms = _sinceStart.elapsedMilliseconds;
    _favouritesAtMs = ms;
    final line =
        'favourites rendered in ${ms}ms with $favouriteCount favourites';
    developer.log(line, name: 'STARTUP_TRACE');
    // AND on stdout, deliberately. `dart:developer` is not forwarded by
    // `flutter run`, so reading it needs a VM-service tap — and a tap cannot
    // connect until after the app has started, which is after this fires. The
    // measurement would be lost to that race on every cold start, which is
    // the only kind of start worth measuring.
    debugPrint('STARTUP_TRACE: $line');
  }

  /// The figure this phase reports: ms from launch to the first favourites
  /// paint, or null if it has not happened.
  ///
  /// Exposed because asserting on the boolean flag alone was not enough —
  /// mutation-checked: removing the one-shot guard left the flag true and the
  /// suite green while the recorded VALUE was overwritten on every rebuild,
  /// turning a cold-start figure into "time since the last frame".
  static int? get favouritesRenderedAtMs => _favouritesAtMs;

  /// Test seam: forget that the mark was taken.
  static void resetForTest() {
    _favouritesMarked = false;
    _favouritesAtMs = null;
    _sinceStart
      ..reset()
      ..stop();
  }

  /// Test seam: whether the one-shot mark has been consumed.
  static bool get hasMarkedForTest => _favouritesMarked;
}
