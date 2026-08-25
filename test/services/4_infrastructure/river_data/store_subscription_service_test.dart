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
    test('an NWM reach watches the four stored products, not all six', () {
      final ids = StoreSubscriptionService.documentIdsFor([_key('1')]);
      expect(ids, {
        'nwm__1__analysisAssimilation',
        'nwm__1__shortRange',
        'nwm__1__mediumRange',
        'nwm__1__longRange',
      });
      // The source supports these, but the store never writes them, so a
      // listener on them could only ever cost money and never fire.
      expect(ids, isNot(contains('nwm__1__returnPeriods')));
      expect(ids, isNot(contains('nwm__1__reachMetadata')));
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
        4,
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
      final many = List.generate(20, (i) => _key('r$i')); // 20 x 4 = 80 ids
      await svc.syncFavourites(many);

      expect(svc.watchedIds, hasLength(80));
      for (var i = 0; i < 20; i++) {
        expect(svc.watchedIds, contains('nwm__r${i}__shortRange'));
      }
      await svc.dispose();
    });
  });
}
