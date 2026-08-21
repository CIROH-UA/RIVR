import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

// Guards for the cold-start race on the Weekly Outlook page.
//
// A notification tap pushes this page during launch, before FavoritesProvider
// has finished loading from Firestore. The page read favourites once with
// `context.read` — which does not subscribe — so an account with three
// favourites saw "Add favorite rivers to get your weekly outlook" and never
// recovered. It also meant _recordOutlookOpen never ran, so the digest
// back-off counter never reset: the very notification the user tapped pushed
// them one step closer to being throttled to biweekly.
//
// This models the page's load state machine exactly as implemented. The page
// itself needs GetIt, Provider and Firebase to pump, so the rule is pinned
// here and the widget wiring is verified on device.

/// Mirrors `_WeeklyOutlookPageState`'s loading logic, minus the widgets.
class OutlookLoadModel {
  OutlookLoadModel({this.grace = const Duration(seconds: 8)});

  final Duration grace;

  List<String> providerFavorites = const [];

  bool loading = true;
  bool outlookBuilt = false;
  int buildOutlookCalls = 0;
  int recordOpenCalls = 0;
  Timer? _fallback;

  bool get showsEmptyState => !loading && !outlookBuilt;

  void load() {
    if (outlookBuilt) return;
    if (providerFavorites.isEmpty) {
      _fallback ??= Timer(grace, () {
        if (outlookBuilt) return;
        loading = false; // genuinely empty account
      });
      return;
    }
    outlookBuilt = true;
    _fallback?.cancel();
    buildOutlookCalls++;
    loading = false;
    recordOpenCalls++; // resets the digest back-off counter
  }

  /// FavoritesProvider notified its listeners.
  void onFavoritesChanged() {
    if (outlookBuilt) return;
    if (providerFavorites.isNotEmpty) load();
  }

  /// Favourites arrive from Firestore after the page is already on screen.
  void favouritesArrive(List<String> favs) {
    providerFavorites = favs;
    onFavoritesChanged();
  }

  void dispose() => _fallback?.cancel();
}

void main() {
  group('guard 1 — favourites arriving late still build the outlook', () {
    test('the empty state is not shown while favourites are still loading',
        () {
      final m = OutlookLoadModel();
      m.load(); // page opened before the provider finished

      expect(m.loading, isTrue, reason: 'must hold the spinner, not give up');
      expect(m.showsEmptyState, isFalse,
          reason: 'this is the bug: three favourites, "no favourites" shown');
      m.dispose();
    });

    test('outlook builds once favourites arrive', () {
      final m = OutlookLoadModel();
      m.load();
      m.favouritesArrive(['White River', 'Dead River', 'Provo River']);

      expect(m.outlookBuilt, isTrue);
      expect(m.buildOutlookCalls, 1);
      expect(m.loading, isFalse);
      expect(m.showsEmptyState, isFalse);
      m.dispose();
    });

    // The compounding failure: not opening the outlook leaves the back-off
    // counter climbing, so tapping digests looks identical to ignoring them.
    test('a late-loading outlook still records the open', () {
      final m = OutlookLoadModel();
      m.load();
      m.favouritesArrive(['White River']);

      expect(m.recordOpenCalls, 1,
          reason: 'opening the outlook must reset the digest back-off');
      m.dispose();
    });
  });

  group('guard 2 — the outlook is built exactly once', () {
    test('repeated provider notifications do not rebuild', () {
      final m = OutlookLoadModel();
      m.load();
      m.favouritesArrive(['White River']);
      m.onFavoritesChanged();
      m.onFavoritesChanged();
      m.onFavoritesChanged();

      expect(m.buildOutlookCalls, 1);
      expect(m.recordOpenCalls, 1);
      m.dispose();
    });

    test('favourites present on first read build immediately', () {
      final m = OutlookLoadModel()..providerFavorites = ['White River'];
      m.load();

      expect(m.buildOutlookCalls, 1);
      expect(m.loading, isFalse);
      m.dispose();
    });
  });

  group('guard 3 — a genuinely empty account still gets the empty state', () {
    test('the empty state appears after the grace period', () {
      fakeAsync((elapse) {
        final m = OutlookLoadModel(grace: const Duration(seconds: 8));
        m.load();
        expect(m.showsEmptyState, isFalse, reason: 'not yet — still waiting');

        elapse(const Duration(seconds: 9));

        expect(m.loading, isFalse);
        expect(m.showsEmptyState, isTrue,
            reason: 'no favourites ever arrived — say so');
        m.dispose();
      });
    });

    test('favourites arriving before the deadline cancel the empty state', () {
      fakeAsync((elapse) {
        final m = OutlookLoadModel(grace: const Duration(seconds: 8));
        m.load();
        elapse(const Duration(seconds: 3));
        m.favouritesArrive(['White River']);
        elapse(const Duration(seconds: 10));

        expect(m.showsEmptyState, isFalse,
            reason: 'the fallback must not fire after a successful build');
        expect(m.buildOutlookCalls, 1);
        m.dispose();
      });
    });
  });
}

/// Minimal fake-async helper so the grace period does not cost real seconds.
void fakeAsync(void Function(void Function(Duration)) body) {
  runZonedGuarded(() {
    final pending = <_Scheduled>[];
    var now = Duration.zero;

    runZoned(
      () => body((d) {
        now += d;
        pending
          ..sort((a, b) => a.at.compareTo(b.at))
          ..removeWhere((t) {
            if (t.at <= now && !t.cancelled) {
              t.callback();
              return true;
            }
            return t.cancelled;
          });
      }),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          final t = _Scheduled(now + duration, f);
          pending.add(t);
          return t;
        },
      ),
    );
  }, (e, s) => fail('unexpected error: $e'));
}

class _Scheduled implements Timer {
  _Scheduled(this.at, this.callback);
  final Duration at;
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}
