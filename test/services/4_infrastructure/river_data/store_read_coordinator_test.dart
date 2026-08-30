// test/services/4_infrastructure/river_data/store_read_coordinator_test.dart
//
// ADR 0011 Phase 5, guard 9 — the kill switch.
//
// The ADR's reason for it is the reason these tests are strict: "an app release
// takes days — if the store serves something wrong, the fix cannot wait on
// Apple." A switch that only prevents NEW subscriptions is not a kill switch,
// because the devices that already hold listeners are exactly the ones serving
// the wrong number.
//
// The one-way bug these pin: the coordinator originally called the
// subscription service's `dispose`, which is terminal. Turning the switch off
// and back on left the store permanently detached until an app restart.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_coordinator.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_switch.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';

class _NoopRepo implements IRiverDataRepository {

  // Phase 7: the fakes never go out of sync — a test that needs the indicator
  // drives it explicitly rather than inheriting a default that could hide a
  // real regression.
  @override
  final ValueListenable<bool> outOfSync = ValueNotifier<bool>(false);
  final List<RiverDataEntry> ingested = [];
  @override
  Future<void> ingest(RiverDataEntry e) async => ingested.add(e);
  @override
  Future<RiverDataEntry?> read(RiverDataKey k) async => null;
  @override
  Future<RiverDataEntry?> refresh(RiverDataKey k) async => null;
  @override
  ValueListenable<RiverDataEntry?> watch(RiverDataKey k) =>
      ValueNotifier<RiverDataEntry?>(null);
}

/// A switch whose value the test drives directly, standing in for Remote
/// Config. The real class is a thin wrapper over `getBool`.
/// The kill switch evicts store-written entries so the live path takes over
/// immediately; these tests care about subscriptions, not eviction.
class _NoopCache implements IRiverDataCache {
  final List<RiverDataKey> evicted = [];
  @override
  Future<void> evict(RiverDataKey key) async => evicted.add(key);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeSwitch implements StoreReadSwitch {
  _FakeSwitch(this._enabled);
  bool _enabled;

  @override
  final ChangeNotifier changes = ChangeNotifier();

  bool get enabled => _enabled;

  /// Flip it the way Remote Config does: change the value AND announce it.
  set enabled(bool v) {
    _enabled = v;
    // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
    changes.notifyListeners();
  }

  @override
  bool get isStoreReadEnabled => _enabled;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> dispose() async => changes.dispose();
}

/// Stands in for the favourites provider: a Listenable whose contents the test
/// controls.
class _FakeFavourites extends ChangeNotifier {
  _FakeFavourites(this.reaches);
  List<({ForecastSource source, String reachId})> reaches;
  void set(List<({ForecastSource source, String reachId})> next) {
    reaches = next;
    notifyListeners();
  }
}

({ForecastSource source, String reachId}) _nwm(String id) =>
    (source: ForecastSource.nwm, reachId: id);

void main() {
  late FakeFirebaseFirestore db;
  late StoreSubscriptionService subs;
  late _FakeFavourites favourites;

  setUp(() {
    db = FakeFirebaseFirestore();
    subs = StoreSubscriptionService(repository: _NoopRepo(), firestore: db);
    favourites = _FakeFavourites([_nwm('1')]);
  });

  StoreReadCoordinator build(_FakeSwitch sw) => StoreReadCoordinator(
        subscriptions: subs,
        readSwitch: sw,
        cache: _NoopCache(),
        favouritesListenable: favourites,
        favourites: () => favourites.reaches,
      );

  group('the kill switch decides whether this device reads the store', () {
    test('enabled: attaching subscribes to the favourites', () async {
      final c = build(_FakeSwitch(true));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(c.isActive, isTrue);
      expect(subs.watchedIds, contains('nwm__1__shortRange'));
      await c.dispose();
    });

    test('disabled: attaching subscribes to nothing', () async {
      final c = build(_FakeSwitch(false));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(c.isActive, isFalse);
      expect(subs.watchedIds, isEmpty);
      await c.dispose();
    });

    // The whole point. A switch that only blocks NEW subscriptions leaves the
    // already-affected devices serving the wrong number.
    test('turning it OFF detaches a device that is already subscribed',
        () async {
      final sw = _FakeSwitch(true);
      final c = build(sw);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c.isActive, isTrue);

      sw.enabled = false;
      await c.sync();

      expect(c.isActive, isFalse,
          reason: 'devices already reading the store must let go');
      expect(subs.watchedIds, isEmpty);
      await c.dispose();
    });

    // The one-way bug. The coordinator used to call the terminal dispose here,
    // so the store never came back without an app restart.
    test('turning it OFF then ON again resumes, without a restart', () async {
      final sw = _FakeSwitch(true);
      final c = build(sw);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      sw.enabled = false;
      await c.sync();
      expect(c.isActive, isFalse);

      sw.enabled = true;
      await c.sync();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(c.isActive, isTrue,
          reason: 'a switch that cannot be turned back on is not a switch');
      expect(subs.watchedIds, contains('nwm__1__shortRange'));
      await c.dispose();
    });
  });

  group('following the favourites', () {
    test('adding a favourite extends the watch set', () async {
      final c = build(_FakeSwitch(true));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      favourites.set([_nwm('1'), _nwm('2')]);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(subs.watchedIds, contains('nwm__2__shortRange'));
      expect(subs.watchedIds, hasLength(12)); // 2 reaches x 6 products
      await c.dispose();
    });

    test('removing every favourite leaves nothing subscribed', () async {
      final c = build(_FakeSwitch(true));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      favourites.set(const []);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(c.isActive, isFalse);
      await c.dispose();
    });

    test('a GEOGLOWS favourite watches its own product', () async {
      favourites = _FakeFavourites([
        (source: ForecastSource.geoglows, reachId: '9'),
      ]);
      final c = build(_FakeSwitch(true));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(subs.watchedIds, {'geoglows__9__geoglowsForecast'});
      await c.dispose();
    });
  });

  group('lifecycle', () {
    test('dispose stops following the favourites', () async {
      final c = build(_FakeSwitch(true));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await c.dispose();
      expect(c.isActive, isFalse);

      // A favourites change after dispose must not resurrect anything.
      favourites.set([_nwm('1'), _nwm('2')]);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.isActive, isFalse);
      expect(subs.watchedIds, isEmpty);
    });

    test('dispose is idempotent', () async {
      final c = build(_FakeSwitch(true));
      await c.dispose();
      expect(c.dispose(), completes);
    });

    test('sync after dispose does nothing', () async {
      final c = build(_FakeSwitch(true));
      await c.dispose();
      await c.sync();
      expect(c.isActive, isFalse);
    });
  });

  group('round 1, B2/B4 — the switch must reach a RUNNING app', () {
    // The bug: sync() ran only from attach() and the favourites listener, and
    // attach() happens at startup while Remote Config is still resolving — so
    // the switch read false almost every time. Nothing re-synced when it
    // changed. A flip to false never reached the devices it exists to rescue,
    // and a late-resolving fetch left the store silently off for the session.
    test('a flip to ON activates without any favourites change', () async {
      final sw = _FakeSwitch(false);
      final c = build(sw);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.isActive, isFalse);

      // Remote Config resolves late. Nobody touches favourites.
      sw.enabled = true;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(c.isActive, isTrue,
          reason: 'the store must activate when the switch does, not only '
              'when a favourite happens to change');
      await c.dispose();
    });

    test('a flip to OFF detaches without any favourites change', () async {
      final sw = _FakeSwitch(true);
      final c = build(sw);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.isActive, isTrue);

      sw.enabled = false;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(c.isActive, isFalse,
          reason: 'this is the whole point of a kill switch: it has to reach '
              'devices already reading the store');
      await c.dispose();
    });

    test('dispose stops following the switch too', () async {
      final sw = _FakeSwitch(false);
      final c = build(sw);
      await c.dispose();

      sw.enabled = true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.isActive, isFalse);
    });
  });

  group('round 3, B2 — the switch must RECLAIM, not just stop ingesting', () {
    // Detaching stops new writes and reclaims nothing. Entries the listener
    // already put in the shared cache are served by RiverDataRepository.read
    // as fresh, with no source call — for up to an hour for the flow products
    // and THIRTY DAYS for the river name and the flood thresholds. So a store
    // serving a wrong threshold survived its own kill switch by a month, while
    // StoreReadSwitch's class comment promised every open app returns to the
    // live path "within seconds".
    test('flipping OFF evicts every product the store could have written',
        () async {
      final cache = _NoopCache();
      final sw = _FakeSwitch(true);
      favourites = _FakeFavourites([_nwm('1'), _nwm('2')]);
      final c = StoreReadCoordinator(
        subscriptions: subs,
        readSwitch: sw,
        cache: cache,
        favouritesListenable: favourites,
        favourites: () => favourites.reaches,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.isActive, isTrue);

      sw.enabled = false;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final keys = cache.evicted.map((k) => k.storageKey).toSet();
      expect(keys, hasLength(12),
          reason: '2 reaches x 6 stored products must all be reclaimed');
      expect(keys, contains('nwm__1__returnPeriods'),
          reason: 'the 30-day thresholds are the entry that outlives the '
              'switch by the longest, so they matter most');
      expect(keys, contains('nwm__1__reachMetadata'));
      expect(keys, contains('nwm__2__shortRange'));
      await c.dispose();
    });

    test('with the switch ON nothing is evicted', () async {
      final cache = _NoopCache();
      final c = StoreReadCoordinator(
        subscriptions: subs,
        readSwitch: _FakeSwitch(true),
        cache: cache,
        favouritesListenable: favourites,
        favourites: () => favourites.reaches,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(cache.evicted, isEmpty,
          reason: 'evicting on the happy path would throw away every value '
              'the store just delivered and refetch it upstream');
      await c.dispose();
    });
  });

  group('round 4, B1 — eviction is a TRANSITION, not a state', () {
    // The round-3 eviction fix ran whenever the switch read false. False is
    // the DEFAULT and `store_read_enabled` does not exist in Remote Config, so
    // that was the shipping path — and FavoritesProvider notifies from eleven
    // places, at least three times per launch. Every one wiped each
    // favourite's entries from memory AND disk. Favourites are the PINNED
    // reaches ADR 0011 Phase 2 exists to protect, so the phase made the app
    // fetch MORE than before it, and an offline launch lost the last-known
    // values for exactly the reaches the user cares about.
    test('the default-OFF state never evicts, however often favourites notify',
        () async {
      final cache = _NoopCache();
      favourites = _FakeFavourites([_nwm('1'), _nwm('2')]);
      final c = StoreReadCoordinator(
        subscriptions: subs,
        readSwitch: _FakeSwitch(false),
        cache: cache,
        favouritesListenable: favourites,
        favourites: () => favourites.reaches,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      for (var i = 0; i < 5; i++) {
        favourites.set([_nwm('1'), _nwm('2')]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(cache.evicted, isEmpty,
          reason: 'the store was never on, so there is nothing to reclaim — '
              'and wiping the pinned favourites is a REGRESSION on the live '
              'path, not a no-op');
      await c.dispose();
    });

    test('only the ON -> OFF transition evicts, and only once', () async {
      final cache = _NoopCache();
      final sw = _FakeSwitch(true);
      final c = StoreReadCoordinator(
        subscriptions: subs,
        readSwitch: sw,
        cache: cache,
        favouritesListenable: favourites,
        favourites: () => favourites.reaches,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cache.evicted, isEmpty);

      sw.enabled = false;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final afterFlip = cache.evicted.length;
      expect(afterFlip, greaterThan(0));

      // Further churn while still off must not evict again.
      favourites.set([_nwm('1')]);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(cache.evicted.length, afterFlip,
          reason: 'eviction is the transition, not the state');
      await c.dispose();
    });
  });

  group('round 5, B5 — the reclaim must survive a relaunch', () {
    // The transition gate is only useful if it persists: a device that WAS
    // reading the store and is force-quit must still reclaim on next launch,
    // rather than serving poisoned entries from disk until they expire — up to
    // 30 days for names and thresholds. Every other coordinator test runs
    // without the SharedPreferences plugin and therefore exercises the catch
    // branch, so this mechanism was entirely unguarded: round 5 made the flag
    // write-only and all 1162 tests passed.
    setUp(() => SharedPreferences.setMockInitialValues({}));

    // THE gap that test missed: it populates `favourites` BEFORE constructing
    // the coordinator. Production does the opposite. `_attach` runs at startup
    // while Remote Config is still resolving — the comment above `_attach`
    // says the switch "reads false here almost every time" — and at that
    // instant FavoritesProvider has not loaded, so `_favourites()` is empty.
    //
    // The reclaim therefore evicted nothing and then cleared the persisted
    // flag anyway, so it could never fire again for that install. Flip the
    // switch OFF, force-quit, relaunch, and store-written names and thresholds
    // survive their full 30-day window — verbatim the failure the persistence
    // exists to prevent.
    test('favourites arriving LATE still get reclaimed', () async {
      SharedPreferences.setMockInitialValues(
          {'adr0011_store_was_active': true});
      final cache = _NoopCache();
      final late = _FakeFavourites(const []); // empty, as at real startup

      final c = StoreReadCoordinator(
        subscriptions: subs,
        readSwitch: _FakeSwitch(false),
        cache: cache,
        favouritesListenable: late,
        favourites: () => late.reaches,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(cache.evicted, isEmpty,
          reason: 'nothing to evict yet — there were no favourites');

      // FavoritesProvider finishes loading and notifies, exactly as it does a
      // few hundred ms into a real launch.
      late.set(favourites.reaches);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(cache.evicted, isNotEmpty,
          reason: 'the persisted flag must survive an empty first pass, or '
              'the cross-launch reclaim is a no-op on every real device');
      c.dispose();
    });

    test('a flag left true by a previous session evicts on the next launch',
        () async {
      SharedPreferences.setMockInitialValues(
          {'adr0011_store_was_active': true});
      final cache = _NoopCache();

      // Fresh process, switch already OFF — nothing in memory says the store
      // was ever on, so only the persisted flag can drive the reclaim.
      final c = StoreReadCoordinator(
        subscriptions: subs,
        readSwitch: _FakeSwitch(false),
        cache: cache,
        favouritesListenable: favourites,
        favourites: () => favourites.reaches,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(cache.evicted, isNotEmpty,
          reason: 'a force-quit must not let poisoned entries outlive the '
              'kill switch');
      await c.dispose();
    });

    test('no flag means no eviction on a fresh install', () async {
      SharedPreferences.setMockInitialValues({});
      final cache = _NoopCache();
      final c = StoreReadCoordinator(
        subscriptions: subs,
        readSwitch: _FakeSwitch(false),
        cache: cache,
        favouritesListenable: favourites,
        favourites: () => favourites.reaches,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(cache.evicted, isEmpty);
      await c.dispose();
    });

    test('turning the store ON persists the flag for the next launch',
        () async {
      SharedPreferences.setMockInitialValues({});
      final c = StoreReadCoordinator(
        subscriptions: subs,
        readSwitch: _FakeSwitch(true),
        cache: _NoopCache(),
        favouritesListenable: favourites,
        favourites: () => favourites.reaches,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('adr0011_store_was_active'), isTrue,
          reason: 'without this the next launch cannot know to reclaim');
      await c.dispose();
    });
  });
}
