// test/services/4_infrastructure/river_data/store_read_switch_test.dart
//
// ADR 0011 Phase 5, guard 9 — the kill switch, at the level where it actually
// lives.
//
// Round 2 found this class had NO tests at all. The coordinator suite tests a
// hand-written `_FakeSwitch` with none of the real Remote Config logic, which
// is the fake-guard shape the ADR warns about: a guard written a layer above
// the thing it claims to prevent. Everything below drives the real class.
//
// The three properties that cost something when wrong:
//   - a fetch that fails must not cost the listener (the switch would be
//     unable to change, in BOTH directions, for the whole session)
//   - a value activated earlier must survive an offline launch (guard 4)
//   - it must never call setDefaults on the shared FirebaseRemoteConfig
//     instance, because FloodTilesetService initialises the same singleton and
//     setDefaults replaces rather than merges

import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rivr/services/4_infrastructure/river_data/store_read_switch.dart';

/// A stand-in for FirebaseRemoteConfig driven directly by the test.
///
/// `noSuchMethod` covers the wide surface of the real class; only what this
/// switch touches is implemented.
class _FakeRc implements FirebaseRemoteConfig {
  _FakeRc({this.value = false, this.fetchThrows = false});

  /// The activated value, as Remote Config would persist it across launches.
  bool value;

  /// Simulates an offline launch or a fetch slower than the timeout.
  bool fetchThrows;

  int setDefaultsCalls = 0;
  int fetchCalls = 0;
  int activateCalls = 0;

  final StreamController<RemoteConfigUpdate> _updates =
      StreamController<RemoteConfigUpdate>.broadcast();

  bool get hasUpdateListener => _updates.hasListener;

  void pushUpdate({Set<String>? keys}) {
    _updates.add(RemoteConfigUpdate(
        keys ?? {StoreReadSwitch.keyStoreReadEnabled}));
  }

  @override
  bool getBool(String key) =>
      key == StoreReadSwitch.keyStoreReadEnabled ? value : false;

  @override
  Stream<RemoteConfigUpdate> get onConfigUpdated => _updates.stream;

  @override
  Future<void> setConfigSettings(RemoteConfigSettings settings) async {}

  @override
  Future<void> setDefaults(Map<String, dynamic> defaults) async {
    setDefaultsCalls++;
  }

  @override
  Future<bool> fetchAndActivate() async {
    fetchCalls++;
    if (fetchThrows) throw Exception('offline');
    return true;
  }

  @override
  Future<bool> activate() async {
    activateCalls++;
    return true;
  }

  Future<void> close() => _updates.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('the default is OFF, and it is the SAFE default', () {
    test('a key that was never fetched reads false', () async {
      final rc = _FakeRc(value: false);
      final s = StoreReadSwitch(remoteConfig: rc);
      expect(s.isStoreReadEnabled, isFalse);
      await s.initialize();
      expect(s.isStoreReadEnabled, isFalse);
      await s.dispose();
      await rc.close();
    });

    test('a failed fetch on a first install leaves it OFF', () async {
      final rc = _FakeRc(value: false, fetchThrows: true);
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();
      expect(s.isStoreReadEnabled, isFalse,
          reason: 'never trust a store the device could not ask about');
      await s.dispose();
      await rc.close();
    });
  });

  group('guard 4 — an activated value survives an offline launch', () {
    // The bug this pins: isStoreReadEnabled was `_ready && getBool(...)`, and
    // `_ready` was set only after a SUCCESSFUL fetch. A user who was online
    // yesterday with the store enabled, launching offline today, had the
    // switch read false — so nothing rendered from the store on exactly the
    // launch the offline guard exists for.
    test('a previously activated true is kept when today\'s fetch fails',
        () async {
      final rc = _FakeRc(value: true, fetchThrows: true);
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();

      expect(rc.fetchCalls, 1, reason: 'it must still try');
      expect(s.isStoreReadEnabled, isTrue,
          reason: 'Remote Config persists activated values; an offline launch '
              'must not discard yesterday\'s answer');
      await s.dispose();
      await rc.close();
    });
  });

  group('a failed fetch must not cost the listener', () {
    // The switch exists because "an app release takes days". A single failed
    // launch-time fetch leaving it unable to change for the session — in both
    // directions — defeats the entire reason for it.
    test('the update listener is subscribed even when the fetch throws',
        () async {
      final rc = _FakeRc(value: false, fetchThrows: true);
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();

      expect(rc.hasUpdateListener, isTrue,
          reason: 'subscribe BEFORE fetching, or a bad launch is terminal');

      // And it can still recover mid-session.
      var notified = 0;
      s.changes.addListener(() => notified++);
      rc.value = true;
      rc.pushUpdate();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(s.isStoreReadEnabled, isTrue);
      expect(notified, greaterThan(0),
          reason: 'a running app must be told, not just updated silently');
      await s.dispose();
      await rc.close();
    });

    test('a live flip to OFF is announced', () async {
      final rc = _FakeRc(value: true);
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();
      expect(s.isStoreReadEnabled, isTrue);

      var notified = 0;
      s.changes.addListener(() => notified++);
      rc.value = false;
      rc.pushUpdate();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(s.isStoreReadEnabled, isFalse);
      expect(notified, greaterThan(0));
      await s.dispose();
      await rc.close();
    });

    test('an unrelated key changing does not announce', () async {
      final rc = _FakeRc(value: false);
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();

      var notified = 0;
      s.changes.addListener(() => notified++);
      rc.pushUpdate(keys: {'flood_tileset_id'});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(notified, 0, reason: 'the flood pipeline republishes daily; '
          'resyncing every listener on its updates is pure waste');
      await s.dispose();
      await rc.close();
    });
  });

  group('it shares FirebaseRemoteConfig.instance with FloodTilesetService', () {
    // Round 2, B6. Both are initialised unawaited from main() against the same
    // singleton. setDefaults REPLACES the defaults map rather than merging, so
    // whichever landed second wiped the other's.
    test('setDefaults is never called', () async {
      final rc = _FakeRc(value: false);
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();
      expect(rc.setDefaultsCalls, 0,
          reason: 'setDefaults on the shared instance wipes '
              'FloodTilesetService\'s defaults');
      await s.dispose();
      await rc.close();
    });
  });

  group('lifecycle', () {
    test('dispose stops the update subscription', () async {
      final rc = _FakeRc(value: false);
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();
      expect(rc.hasUpdateListener, isTrue);

      await s.dispose();
      expect(rc.hasUpdateListener, isFalse,
          reason: 'an orphaned Remote Config listener is a leak');
      await rc.close();
    });

    test('initialize twice does not double-subscribe', () async {
      final rc = _FakeRc(value: false);
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();
      await s.initialize();

      var notified = 0;
      s.changes.addListener(() => notified++);
      rc.pushUpdate();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(notified, 1, reason: 'two listeners would notify twice per change');
      await s.dispose();
      await rc.close();
    });
  });
  // ── isResolved: the coordinator's licence to EVICT ───────────────────────
  //
  // `isStoreReadEnabled` reads false both for "the operator turned this off"
  // and for "we have not fetched yet", and the coordinator now refuses to
  // reclaim until `isResolved` says the value is a decision. Two mutations
  // showed this was entirely unpinned in production code: deleting the
  // `_resolved = true` from the failed-fetch branch, and hardcoding
  // `isResolved => false`, both left every coordinator test green. The second
  // means the kill switch's reclaim never fires on any device, which is the
  // exact failure Decision 23 exists to prevent.
  //
  // Every coordinator test uses a fake that overrides `isResolved`, so only
  // these can reach the real getter.
  group('isResolved', () {
    test('is false before initialize', () {
      final rc = _FakeRc();
      final s = StoreReadSwitch(remoteConfig: rc);
      expect(s.isResolved, isFalse,
          reason: 'nothing has been fetched; a false switch here is an '
              'absence of information, not a decision');
    });

    test('is true after a successful fetch', () async {
      final rc = _FakeRc();
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();
      expect(s.isResolved, isTrue);
    });

    // A failed fetch STILL resolves: Remote Config then serves the last
    // activated value, and that is the operator's decision. Without this the
    // reclaim would be permanently disabled on any device that happened to be
    // offline at launch.
    test('is true even when the fetch throws', () async {
      final rc = _FakeRc()..fetchThrows = true;
      final s = StoreReadSwitch(remoteConfig: rc);
      await s.initialize();
      expect(s.isResolved, isTrue,
          reason: 'an offline launch must not disable the kill switch for the '
              'rest of the session');
    });
  });

}
