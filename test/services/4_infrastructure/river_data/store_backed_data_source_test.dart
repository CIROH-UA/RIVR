// test/services/4_infrastructure/river_data/store_backed_data_source_test.dart
//
// ADR 0011 Phase 5, guard 1: "a favourite renders with ZERO upstream calls
// from the device."
//
// Round 2's finding was not that the number was wrong — it was that NO TEST
// ASSERTED IT. The guard was checked one layer above the fetch it claimed to
// prevent: `_CapturingRepo` recorded `ingest` calls, which says the store
// delivered something, not that upstream went unasked.
//
// Every test here counts calls on the WRAPPED SOURCE. That is the layer the
// upstream call actually happens at, so a count of zero means zero.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_backed_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_switch.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';

/// The live path. Every call to this is a call to NOAA in production.
class _CountingSource implements IRiverDataSource {
  int fetches = 0;
  final List<RiverDataKey> fetched = [];

  @override
  ForecastSource get source => ForecastSource.nwm;

  @override
  Set<ForecastProduct> get supportedProducts => const {
        ForecastProduct.shortRange,
        ForecastProduct.reachMetadata,
      };

  @override
  DateTime validUntil(ForecastProduct product, DateTime now) =>
      now.add(const Duration(hours: 1));

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    fetches++;
    fetched.add(key);
    return const SourceFetchResult(
      payload: {'from': 'upstream'},
      unit: 'CFS',
      runId: 'upstream-run',
    );
  }
}

class _Switch implements StoreReadSwitch {
  _Switch(this.enabled);
  bool enabled;
  @override
  bool get isStoreReadEnabled => enabled;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

RiverDataKey _key([ForecastProduct p = ForecastProduct.shortRange]) =>
    RiverDataKey(source: ForecastSource.nwm, reachId: '123', product: p);

/// A document as the server writes it — `RiverDataEntry.toJson()`.
Map<String, dynamic> _storeDoc({
  Duration validFor = const Duration(hours: 1),
  int schema = RiverDataEntry.schemaVersion,
  String reachId = '123',
  ForecastProduct product = ForecastProduct.shortRange,
}) {
  final now = DateTime.now().toUtc();
  final json = RiverDataEntry(
    key: RiverDataKey(
        source: ForecastSource.nwm, reachId: reachId, product: product),
    window: FreshnessWindow(fetchedAt: now, validUntil: now.add(validFor)),
    unit: 'CMS',
    runId: 'store-run',
    payload: const {'from': 'store'},
  ).toJson();
  json['schema'] = schema;
  return json;
}

void main() {
  late FakeFirebaseFirestore db;
  late _CountingSource upstream;

  setUp(() {
    db = FakeFirebaseFirestore();
    upstream = _CountingSource();
  });

  StoreBackedDataSource build(_Switch sw) => StoreBackedDataSource(
        inner: upstream,
        readSwitch: sw,
        firestore: db,
      );

  Future<void> seed({
    Duration validFor = const Duration(hours: 1),
    int schema = RiverDataEntry.schemaVersion,
    ForecastProduct product = ForecastProduct.shortRange,
  }) async {
    final key = RiverDataKey(
        source: ForecastSource.nwm, reachId: '123', product: product);
    await db
        .collection(kStoreCollection)
        .doc(key.storageKey)
        .set(_storeDoc(validFor: validFor, schema: schema, product: product));
  }

  group('guard 1 — a stored favourite costs ZERO upstream calls', () {
    test('a fresh store document is served and upstream is never asked',
        () async {
      await seed();
      final s = build(_Switch(true));

      final r = await s.fetch(_key());

      expect(upstream.fetches, 0,
          reason: 'THIS is guard 1: the live path must not be called at all');
      expect(r.payload['from'], 'store');
      expect(r.unit, 'CMS', reason: 'the store\'s native unit, not the live '
          'path\'s user-preference unit');
      expect(r.runId, 'store-run');
      expect(s.servedFromStore, 1);
      expect(s.servedFromUpstream, 0);
    });

    test('repeated reads stay at zero upstream calls', () async {
      await seed();
      final s = build(_Switch(true));

      for (var i = 0; i < 5; i++) {
        await s.fetch(_key());
      }
      expect(upstream.fetches, 0);
      expect(s.servedFromStore, 5);
    });

    test('the near-static products are served too', () async {
      // The round-1 B3 case: name and thresholds are read by every surface
      // that renders a favourite, so if they miss, the favourite still makes
      // device-side calls and the guard fails no matter how fresh the flow is.
      await seed(product: ForecastProduct.reachMetadata);
      final s = build(_Switch(true));

      await s.fetch(_key(ForecastProduct.reachMetadata));
      expect(upstream.fetches, 0);
    });
  });

  group('it degrades to the live path rather than serving something wrong',
      () {
    test('no document at all falls through', () async {
      final s = build(_Switch(true));
      final r = await s.fetch(_key());

      expect(upstream.fetches, 1);
      expect(r.payload['from'], 'upstream');
    });

    test('an EXPIRED document falls through rather than being served',
        () async {
      await seed(validFor: const Duration(hours: -1));
      final s = build(_Switch(true));

      final r = await s.fetch(_key());
      expect(upstream.fetches, 1,
          reason: 'the store going quiet is exactly when the live path must '
              'take over');
      expect(r.payload['from'], 'upstream');
    });

    test('an unrecognised schema falls through, never parsed', () async {
      await seed(schema: RiverDataEntry.schemaVersion + 1);
      final s = build(_Switch(true));

      final r = await s.fetch(_key());
      expect(upstream.fetches, 1);
      expect(r.payload['from'], 'upstream');
    });

    test('a document filed under the wrong id is refused', () async {
      // Contents disagreeing with the document id means the two sides drifted;
      // ingesting would file this payload under the wrong reach.
      await db
          .collection(kStoreCollection)
          .doc('nwm__123__shortRange')
          .set(_storeDoc(reachId: '999'));
      final s = build(_Switch(true));

      final r = await s.fetch(_key());
      expect(upstream.fetches, 1);
      expect(r.payload['from'], 'upstream');
    });
  });

  group('guard 9 — the kill switch reaches this path too', () {
    test('with the switch OFF the store is not even consulted', () async {
      await seed();
      final s = build(_Switch(false));

      final r = await s.fetch(_key());
      expect(r.payload['from'], 'upstream',
          reason: 'a kill switch that leaves the read path serving the store '
              'is not a kill switch');
      expect(upstream.fetches, 1);
      expect(s.servedFromStore, 0);
    });

    test('flipping the switch changes the next fetch, with no restart',
        () async {
      await seed();
      final sw = _Switch(false);
      final s = build(sw);

      await s.fetch(_key());
      expect(upstream.fetches, 1);

      sw.enabled = true;
      final r = await s.fetch(_key());
      expect(r.payload['from'], 'store');
      expect(upstream.fetches, 1, reason: 'no new upstream call');
    });
  });

  group('the wrapper is transparent (guard 7)', () {
    test('source, products and validUntil all delegate', () {
      final s = build(_Switch(true));
      final now = DateTime.utc(2026, 8, 25, 12);

      expect(s.source, upstream.source);
      expect(s.supportedProducts, upstream.supportedProducts);
      expect(
        s.validUntil(ForecastProduct.shortRange, now),
        upstream.validUntil(ForecastProduct.shortRange, now),
        reason: 'a different freshness window on the two paths would make '
            'store entries expire early and refetch upstream',
      );
    });
  });
}
