// test/services/4_infrastructure/river_data/store_subscription_service_test.dart
//
// ADR 0011 Phase 5. Two things are under test and they fail differently:
//
//  1. **Decoding.** The server writes these documents; this client parses them.
//     Every disagreement between the two is silent — a wrong schema or a
//     mismatched id would ingest a payload under the wrong reach, or decode to
//     nothing, with no error anywhere. So the rejection paths get as much
//     attention as the happy one.
//  2. **Listener lifecycle.** The app has no listeners today. An orphaned one
//     keeps billing Firestore reads forever, which nothing in the UI would ever
//     surface. Cancellation is asserted, not assumed.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';

/// Captures what the service ingests, so delivery can be asserted directly.
class _CapturingRepo implements IRiverDataRepository {
  final List<RiverDataEntry> ingested = [];
  int readCalls = 0;

  @override
  Future<void> ingest(RiverDataEntry entry) async => ingested.add(entry);

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    readCalls++;
    return null;
  }

  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) async => null;

  @override
  ValueListenable<RiverDataEntry?> watch(RiverDataKey key) =>
      ValueNotifier<RiverDataEntry?>(null);
}

RiverDataKey _key(
  String reachId, {
  ForecastSource source = ForecastSource.nwm,
  ForecastProduct product = ForecastProduct.shortRange,
}) =>
    RiverDataKey(source: source, reachId: reachId, product: product);

/// A document exactly as functions/src/store-document.ts writes it.
Map<String, dynamic> _doc({
  String source = 'nwm',
  String reachId = '123',
  String product = 'shortRange',
  int schema = 1,
  String unit = 'CFS',
  String? runId = '2026-08-24T23:00:00Z',
}) =>
    {
      'schema': schema,
      'source': source,
      'reachId': reachId,
      'product': product,
      'window': {
        'fetchedAt': '2026-08-25T03:00:00.000Z',
        'validUntil': '2026-08-25T04:05:00.000Z',
      },
      'unit': unit,
      if (runId != null) 'runId': runId,
      'payload': {
        'reach': {'reachId': reachId},
        'shortRange': {
          'series': {'units': 'ft³/s', 'data': []},
        },
      },
    };

void main() {
  group('decoding a stored document', () {
    test('a well-formed document becomes an entry', () {
      final e = StoreSubscriptionService.decodeDocument(
          'nwm__123__shortRange', _doc());

      expect(e, isNotNull);
      expect(e!.key.storageKey, 'nwm__123__shortRange');
      expect(e.unit, 'CFS');
      expect(e.runId, '2026-08-24T23:00:00Z');
      expect(e.window.validUntil.toIso8601String(),
          startsWith('2026-08-25T04:05:00'));
    });

    // Decision 14: an unrecognised version is DISCARDED, never parsed. A v1
    // client guessing at a v2 shape is how a schema bump becomes silent
    // corruption.
    test('a document from a newer schema is discarded, not parsed', () {
      expect(
        StoreSubscriptionService.decodeDocument(
            'nwm__123__shortRange', _doc(schema: 2)),
        isNull,
      );
    });

    test('a document with no schema at all is discarded', () {
      final d = _doc()..remove('schema');
      expect(
          StoreSubscriptionService.decodeDocument('nwm__123__shortRange', d),
          isNull);
    });

    // The document id IS the cache key. If the contents disagree, ingesting
    // would file this payload under a DIFFERENT river — worse than not
    // ingesting at all, because it would look like data.
    test('a document whose contents disagree with its id is discarded', () {
      expect(
        StoreSubscriptionService.decodeDocument(
            'nwm__999__shortRange', _doc(reachId: '123')),
        isNull,
      );
      expect(
        StoreSubscriptionService.decodeDocument(
            'nwm__123__mediumRange', _doc(product: 'shortRange')),
        isNull,
      );
      expect(
        StoreSubscriptionService.decodeDocument(
            'geoglows__123__shortRange', _doc(source: 'nwm')),
        isNull,
      );
    });

    // Guard 8: degrade to the live path, never throw into the UI.
    test('malformed documents are null rather than a throw', () {
      expect(
          StoreSubscriptionService.decodeDocument('nwm__123__shortRange', null),
          isNull);
      for (final bad in <Map<String, dynamic>>[
        <String, dynamic>{},
        {'schema': 1},
        {'schema': 1, 'source': 'nwm'},
        {'schema': 1, 'source': 'nwm', 'reachId': '123', 'product': 'nope'},
        {...(_doc()..remove('payload'))},
        {...(_doc()..remove('window'))},
      ]) {
        expect(
          () => StoreSubscriptionService.decodeDocument(
              'nwm__123__shortRange', bad),
          returnsNormally,
        );
        expect(
            StoreSubscriptionService.decodeDocument(
                'nwm__123__shortRange', bad),
            isNull);
      }
    });

    test('a document with no runId still decodes', () {
      final e = StoreSubscriptionService.decodeDocument(
          'nwm__123__shortRange', _doc(runId: null));
      expect(e, isNotNull);
      expect(e!.runId, isNull);
    });
  });

  group('which documents get watched', () {
    // This test used to assert the OPPOSITE — that returnPeriods and
    // reachMetadata are NOT watched, on the reasoning that "the store never
    // writes them, so a listener could only cost money and never fire". The
    // reasoning was sound; the premise was the defect. The server did not
    // write them because CAN_FETCH omitted them, and that omission is exactly
    // what made guard 1 ("a favourite renders with ZERO upstream calls from
    // the device") unreachable: name and thresholds are read by every surface
    // that renders a favourite, so each one still made two device-side calls.
    // Phase 5 review round 1, B3. The server now writes both.
    test('an NWM reach watches all six stored products', () {
      final ids = StoreSubscriptionService.documentIdsFor([_key('1')]);
      expect(ids, {
        'nwm__1__analysisAssimilation',
        'nwm__1__shortRange',
        'nwm__1__mediumRange',
        'nwm__1__longRange',
        'nwm__1__reachMetadata',
        'nwm__1__returnPeriods',
      });
    });

    // Guard 1 depends on the app subscribing to exactly what the server
    // writes. A product in one list and not the other fails silently in both
    // directions: a listener that can never fire (billed, useless), or a
    // document written and never delivered.
    test('every watched NWM product is one the server can write', () {
      // Mirrors functions/src/store-upstream.ts CAN_FETCH.nwm. Kept as a
      // literal so drift shows up here rather than on a device.
      const serverWrites = {
        'analysisAssimilation',
        'shortRange',
        'mediumRange',
        'longRange',
        'returnPeriods',
        'reachMetadata',
      };
      final watched = kStoredProducts[ForecastSource.nwm]!
          .map((p) => p.id)
          .toSet();
      expect(watched, serverWrites,
          reason: 'kStoredProducts and CAN_FETCH.nwm must name the same set');
    });

    test('a GEOGLOWS reach watches its one product', () {
      expect(
        StoreSubscriptionService.documentIdsFor(
            [_key('9', source: ForecastSource.geoglows)]),
        {'geoglows__9__geoglowsForecast'},
      );
    });

    test('the product on the key is ignored; all stored products are watched',
        () {
      final a = StoreSubscriptionService.documentIdsFor([_key('1')]);
      final b = StoreSubscriptionService.documentIdsFor(
          [_key('1', product: ForecastProduct.longRange)]);
      expect(a, b);
    });

    test('the same reach twice does not double the watch set', () {
      expect(
        StoreSubscriptionService.documentIdsFor([_key('1'), _key('1')]).length,
        6,
      );
    });
  });

  group('subscribing and delivering', () {
    late FakeFirebaseFirestore db;
    late _CapturingRepo repo;
    late StoreSubscriptionService svc;

    setUp(() {
      db = FakeFirebaseFirestore();
      repo = _CapturingRepo();
      svc = StoreSubscriptionService(repository: repo, firestore: db);
    });

    tearDown(() => svc.dispose());

    test('an existing document is delivered on subscribe', () async {
      await db
          .collection(kStoreCollection)
          .doc('nwm__123__shortRange')
          .set(_doc());

      await svc.syncFavourites([_key('123')]);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(repo.ingested, hasLength(1));
      expect(repo.ingested.single.key.storageKey, 'nwm__123__shortRange');
    });

    // Guard 5: the app does not ask; the write arrives.
    test('a later server write reaches the app without it asking', () async {
      await svc.syncFavourites([_key('123')]);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(repo.ingested, isEmpty);

      await db
          .collection(kStoreCollection)
          .doc('nwm__123__shortRange')
          .set(_doc());
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(repo.ingested, hasLength(1));
      expect(repo.readCalls, 0,
          reason: 'delivery must not go through a read');
    });

    test('an unreadable document is counted and skipped, others still land',
        () async {
      await db
          .collection(kStoreCollection)
          .doc('nwm__123__shortRange')
          .set(_doc(schema: 99));
      await db
          .collection(kStoreCollection)
          .doc('nwm__456__shortRange')
          .set(_doc(reachId: '456'));

      await svc.syncFavourites([_key('123'), _key('456')]);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(svc.rejected, 1);
      expect(repo.ingested.map((e) => e.key.reachId), ['456']);
    });

    test('documents outside the favourite set are not delivered', () async {
      await db
          .collection(kStoreCollection)
          .doc('nwm__999__shortRange')
          .set(_doc(reachId: '999'));

      await svc.syncFavourites([_key('123')]);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(repo.ingested, isEmpty);
    });
  });

  group('listener lifecycle — the leak and billing risk', () {
    late FakeFirebaseFirestore db;
    late _CapturingRepo repo;
    late StoreSubscriptionService svc;

    setUp(() {
      db = FakeFirebaseFirestore();
      repo = _CapturingRepo();
      svc = StoreSubscriptionService(repository: repo, firestore: db);
    });

    test('dispose detaches every listener', () async {
      await svc.syncFavourites([_key('1'), _key('2')]);
      expect(svc.isSubscribed, isTrue);

      await svc.dispose();
      expect(svc.isSubscribed, isFalse);
      expect(svc.watchedIds, isEmpty);

      // A write after dispose must reach nobody.
      await db
          .collection(kStoreCollection)
          .doc('nwm__1__shortRange')
          .set(_doc(reachId: '1'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(repo.ingested, isEmpty);
    });

    test('dispose is idempotent', () async {
      await svc.syncFavourites([_key('1')]);
      await svc.dispose();
      expect(svc.dispose(), completes);
    });

    test('syncing after dispose does nothing', () async {
      await svc.dispose();
      await svc.syncFavourites([_key('1')]);
      expect(svc.isSubscribed, isFalse);
    });

    // Re-attaching re-reads every document, and Firestore bills for it. An
    // unchanged favourite set must therefore be a genuine no-op.
    test('an unchanged favourite set does not re-subscribe', () async {
      await db
          .collection(kStoreCollection)
          .doc('nwm__1__shortRange')
          .set(_doc(reachId: '1'));

      await svc.syncFavourites([_key('1')]);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final first = repo.ingested.length;
      expect(first, greaterThan(0));

      await svc.syncFavourites([_key('1')]);
      await svc.syncFavourites([_key('1', product: ForecastProduct.longRange)]);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(repo.ingested.length, first,
          reason: 're-attaching would re-read and re-bill every document');
      await svc.dispose();
    });

    test('a changed favourite set swaps the watch set', () async {
      await svc.syncFavourites([_key('1')]);
      expect(svc.watchedIds, contains('nwm__1__shortRange'));

      await svc.syncFavourites([_key('2')]);
      expect(svc.watchedIds, contains('nwm__2__shortRange'));
      expect(svc.watchedIds, isNot(contains('nwm__1__shortRange')));
      await svc.dispose();
    });

    test('an empty favourite set subscribes to nothing', () async {
      await svc.syncFavourites([_key('1')]);
      await svc.syncFavourites(const <RiverDataKey>[]);

      expect(svc.isSubscribed, isFalse);
      expect(svc.watchedIds, isEmpty);
      await svc.dispose();
    });

    // Firestore caps whereIn at 30, so more reaches must fan out into more
    // listeners rather than silently truncating the watch set.
    test('more than 30 documents are split across listeners, none dropped',
        () async {
      final many = List.generate(20, (i) => _key('r$i')); // 20 x 6 = 120 ids
      await svc.syncFavourites(many);

      expect(svc.watchedIds, hasLength(120));
      for (var i = 0; i < 20; i++) {
        expect(svc.watchedIds, contains('nwm__r${i}__shortRange'));
      }
      await svc.dispose();
    });
  });

  group('round 1, B1 — concurrent syncs must not duplicate listeners', () {
    late FakeFirebaseFirestore db;
    late _CapturingRepo repo;
    late StoreSubscriptionService svc;

    setUp(() {
      db = FakeFirebaseFirestore();
      repo = _CapturingRepo();
      svc = StoreSubscriptionService(repository: repo, firestore: db);
    });

    tearDown(() => svc.dispose());

    // The bug: syncFavourites awaited _cancelAll() BEFORE assigning _watched.
    // A second call entering that gap still saw the old set, so both calls
    // subscribed and both appended to _subs. The duplicates persisted for the
    // session, so every later write was ingested — and billed — N times.
    //
    // Two favourite changes in one turn is enough to trigger it: each
    // addFavorite/removeFavorite ends in notifyListeners.
    test('two syncs fired without awaiting deliver each write ONCE', () async {
      // Deliberately NOT awaited individually — that is the race.
      final a = svc.syncFavourites([_key('1')]);
      final b = svc.syncFavourites([_key('1'), _key('2')]);
      await Future.wait([a, b]);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      repo.ingested.clear();
      await db
          .collection(kStoreCollection)
          .doc('nwm__1__shortRange')
          .set(_doc(reachId: '1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(repo.ingested, hasLength(1),
          reason: 'a duplicated listener ingests and bills the same write '
              'once per duplicate, for the rest of the session');
    });

    test('rapid-fire syncs settle on the LAST favourite set', () async {
      final futures = [
        svc.syncFavourites([_key('1')]),
        svc.syncFavourites([_key('2')]),
        svc.syncFavourites([_key('3')]),
      ];
      await Future.wait(futures);

      expect(svc.watchedIds, StoreSubscriptionService.documentIdsFor([_key('3')]),
          reason: 'the last call wins; interleaved calls must not merge sets');
    });
  });

  group('round 1, B5 — a listener error must not be terminal', () {
    // Round 2, B2: this test used to call `detach()` and assert on that,
    // while its NAME claimed to exercise the error path. Deleting the fix it
    // was named after left all 99 tests green. It now drives the REAL onError
    // callback through a Firestore whose snapshot stream fails, which is what
    // PERMISSION_DENIED looks like on sign-out.
    test('after a listener ERROR the watch set is cleared so a later sync '
        're-subscribes', () async {
      final db = _ErroringFirestore();
      final svc =
          StoreSubscriptionService(repository: _CapturingRepo(), firestore: db);

      await svc.syncFavourites([_key('1')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(svc.watchedIds, isEmpty,
          reason: 'a dead listener must not leave its ids in the watch set, '
              'or the next sync sees an equal set and early-returns forever');
      expect(svc.isSubscribed, isFalse,
          reason: 'isSubscribed must not report true for a dead stream');

      // The real point: the SAME favourite set must be able to re-subscribe.
      db.failNext = false;
      await svc.syncFavourites([_key('1')]);
      expect(svc.isSubscribed, isTrue,
          reason: 'signing out and back in must not disable the store for the '
              'rest of the session');
      await svc.dispose();
    });

    test('an error on one batch does not tear down the others', () async {
      final db = _ErroringFirestore(failFirstOnly: true);
      final svc =
          StoreSubscriptionService(repository: _CapturingRepo(), firestore: db);

      // 20 reaches x 6 products = 120 ids -> 4 batches of 30.
      await svc.syncFavourites(List.generate(20, (i) => _key('r$i')));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(svc.isSubscribed, isTrue,
          reason: 'one failing batch must not cost the other three');
      await svc.dispose();
    });
  });

  group('round 4, B2 — a heal must never outlive a detach', () {
    // _detachLocked cancelled the heal timer BEFORE awaiting _cancelAll, so a
    // listener error delivered during that await armed a NEW timer the detach
    // would never cancel — and detach did not clear _lastRequested. Seconds
    // later the service re-subscribed with the kill switch OFF, and nothing
    // was left to correct it: the coordinator only re-syncs on a favourites
    // change or a switch flip. The re-attached listener kept calling ingest,
    // and the repository served those entries as fresh WITHOUT consulting any
    // source, so the decorator's switch check never ran. A kill-switch bypass,
    // and the third distinct race in this area.
    test('a listener error during detach does not resurrect the watch',
        () async {
      final db = _ErroringFirestore(failFirstOnly: true);
      final svc =
          StoreSubscriptionService(repository: _CapturingRepo(), firestore: db);

      await svc.syncFavourites([_key('1')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await svc.detach();
      expect(svc.isSubscribed, isFalse);

      // Longer than the first heal delay (2s).
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      expect(svc.isSubscribed, isFalse,
          reason: 'a heal armed before the detach must be refused when it '
              'fires — otherwise the kill switch and sign-out are bypassed');
      expect(svc.watchedIds, isEmpty);
      await svc.dispose();
    });

    test('detach clears what a heal would re-subscribe to', () async {
      final db = _ErroringFirestore(failFirstOnly: true);
      final svc =
          StoreSubscriptionService(repository: _CapturingRepo(), firestore: db);

      await svc.syncFavourites([_key('1')]);
      await svc.detach();
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      expect(svc.isSubscribed, isFalse);
      await svc.dispose();
    });

    // Round 4, M3: restoring round 3's B3 defect — detach() calling
    // _detachLocked() directly instead of chaining on _pending — passed all
    // 1147 tests. The fix was correct and unguarded.
    test('detach WAITS for an in-flight sync instead of racing it', () async {
      final db = _ErroringFirestore(failFirstOnly: false);
      db.failNext = false;
      final svc =
          StoreSubscriptionService(repository: _CapturingRepo(), firestore: db);

      // Start a sync and do NOT await it, then detach immediately. If detach
      // bypasses the lock it runs while the sync is between cancelling the old
      // listeners and installing the new ones, tears down nothing, and the
      // sync then installs listeners the kill switch asked to stop.
      final syncing = svc.syncFavourites([_key('1'), _key('2')]);
      final detaching = svc.detach();
      await Future.wait([syncing, detaching]);

      expect(svc.isSubscribed, isFalse,
          reason: 'detach must observe whatever the sync built and remove it');
      expect(svc.watchedIds, isEmpty);
      await svc.dispose();
    });

    test('a heal still works when nothing detached', () async {
      final db = _ErroringFirestore(failFirstOnly: true);
      final svc =
          StoreSubscriptionService(repository: _CapturingRepo(), firestore: db);

      await svc.syncFavourites([_key('1')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(svc.isSubscribed, isFalse, reason: 'the first stream errored');

      // The self-heal re-subscribes on its own, without the user touching
      // anything — round 3, non-blocking 6.
      await Future<void>.delayed(const Duration(milliseconds: 2400));
      expect(svc.isSubscribed, isTrue,
          reason: 'a mid-session PERMISSION_DENIED must not leave the store '
              'silently off until the user happens to touch a favourite');
      await svc.dispose();
    });
  });
}


// ── A Firestore whose snapshot stream fails ──────────────────────────────────
//
// fake_cloud_firestore has no way to make a listener error, and the error path
// is the one that made the store silently terminal (round 1, B5). These three
// classes implement only the chain the service actually uses —
// collection().where().snapshots() — and let the test decide whether the
// resulting stream errors. `noSuchMethod` absorbs the rest of the surface.

class _ErroringFirestore implements FirebaseFirestore {
  _ErroringFirestore({this.failFirstOnly = false});

  /// Whether the next stream created should fail.
  bool failNext = true;

  /// Fail only the first stream, leaving later batches healthy.
  final bool failFirstOnly;

  int streamsCreated = 0;

  bool takeShouldFail() {
    streamsCreated++;
    if (failFirstOnly) return streamsCreated == 1;
    return failNext;
  }

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _ErroringCollection(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// `CollectionReference` and `Query` are sealed. Implementing them is
// deliberate and confined to this file: the alternative is no test at all for
// the listener-error path, which is the path that made the store silently
// terminal (round 1, B5) and which fake_cloud_firestore cannot produce.
// ignore: subtype_of_sealed_class
class _ErroringCollection implements CollectionReference<Map<String, dynamic>> {
  _ErroringCollection(this.db);
  final _ErroringFirestore db;

  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) =>
      _ErroringQuery(db);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ignore: subtype_of_sealed_class
class _ErroringQuery implements Query<Map<String, dynamic>> {
  _ErroringQuery(this.db);
  final _ErroringFirestore db;

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    if (db.takeShouldFail()) {
      return Stream<QuerySnapshot<Map<String, dynamic>>>.error(
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      );
    }
    return const Stream<QuerySnapshot<Map<String, dynamic>>>.empty();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}