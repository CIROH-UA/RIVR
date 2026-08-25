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

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_coordinator.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_switch.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';

class _NoopRepo implements IRiverDataRepository {
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
        favourites: () => favourites.reaches,
      );

  group('the kill switch decides whether this device reads the store', () {
    test('enabled: attaching subscribes to the favourites', () async {
      final c = build(_FakeSwitch(true));
      c.attach(favourites);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(c.isActive, isTrue);
      expect(subs.watchedIds, contains('nwm__1__shortRange'));
      await c.dispose();
    });

    test('disabled: attaching subscribes to nothing', () async {
      final c = build(_FakeSwitch(false));
      c.attach(favourites);
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
      c.attach(favourites);
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
      c.attach(favourites);
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
      c.attach(favourites);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      favourites.set([_nwm('1'), _nwm('2')]);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(subs.watchedIds, contains('nwm__2__shortRange'));
      expect(subs.watchedIds, hasLength(12)); // 2 reaches x 6 products
      await c.dispose();
    });

    test('removing every favourite leaves nothing subscribed', () async {
      final c = build(_FakeSwitch(true));
      c.attach(favourites);
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
      c.attach(favourites);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(subs.watchedIds, {'geoglows__9__geoglowsForecast'});
      await c.dispose();
    });
  });

  group('lifecycle', () {
    test('dispose stops following the favourites', () async {
      final c = build(_FakeSwitch(true));
      c.attach(favourites);
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
      c.attach(favourites);
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
      c.attach(favourites);
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
      c.attach(favourites);
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
      c.attach(favourites);
      await c.dispose();

      sw.enabled = true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.isActive, isFalse);
    });
  });
}
