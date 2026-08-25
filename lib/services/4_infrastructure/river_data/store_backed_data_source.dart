// lib/services/4_infrastructure/river_data/store_backed_data_source.dart
//
// ADR 0011 Phase 5, guard 1: "a favourite renders with ZERO upstream calls
// from the device."
//
// The ADR specifies this as a DATA-SOURCE SWAP — "for favourited reaches,
// `NwmDataSource` and `GeoglowsDataSource` read the store instead of
// upstream". The first implementation of Phase 5 did something else: it pushed
// documents into the shared cache through `ingest` and relied on
// `RiverDataRepository.read` finding them fresh. Review round 2 showed why
// that cannot satisfy the guard. `read` has three branches, and two of them go
// upstream:
//
//   fresh   -> return cached, no network
//   STALE   -> return cached AND fire a background upstream revalidate
//   MISS    -> fetch upstream
//
// `FavoritesProvider` refreshes every favourite 500 ms after launch, while the
// listener path needs Remote Config, a Firestore query and an ingest to land
// first. Nothing arbitrated that race, so on a cold start — and on any launch
// more than an hour after the last one, because the hourly products are stale
// by then — the device called NOAA anyway. The guard was written one layer
// above the fetch it claimed to prevent, and no test asserted zero calls.
//
// This decorator moves the decision to where the fetch actually happens. When
// the store holds a usable document the upstream call is never made, and that
// is true regardless of listener timing, provider refresh order or staleness.
//
// **It reads the LOCAL cache only** (`Source.cache`). That is not a
// compromise, it is the point:
//   - a favourite's document is already in Firestore's local persistence,
//     put there by the subscription listener, so the read is instant and
//     costs no billed server read (guard 3)
//   - it works with the network off (guard 4)
//   - a NON-favourite is a local miss that falls straight through to the live
//     path, so tapping a random reach on the map cannot bill a server read
//     looking for a document the store was never going to hold
//
// A miss of any kind — no document, wrong schema, unreadable, expired — falls
// through to the wrapped source. Degrading to the live path is always correct
// (guard 8); serving something the store could not vouch for is not.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_switch.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';

/// Wraps a source so favourited reaches are served from the cloud store.
class StoreBackedDataSource implements IRiverDataSource {
  StoreBackedDataSource({
    required IRiverDataSource inner,
    required StoreReadSwitch readSwitch,
    FirebaseFirestore? firestore,
  })  : _inner = inner,
        _switch = readSwitch,
        _db = firestore ?? FirebaseFirestore.instance;

  static const String _tag = 'STORE_SOURCE';

  final IRiverDataSource _inner;
  final StoreReadSwitch _switch;
  final FirebaseFirestore _db;

  /// Store reads that produced a usable entry. Exposed for the guards — this
  /// is the number that says an upstream call did NOT happen.
  int servedFromStore = 0;

  /// Fetches that fell through to the wrapped source.
  int servedFromUpstream = 0;

  @override
  ForecastSource get source => _inner.source;

  @override
  Set<ForecastProduct> get supportedProducts => _inner.supportedProducts;

  /// Delegated deliberately. The freshness window must be the SAME whether a
  /// value came from the store or from upstream, or the two paths would
  /// disagree about when the value expires and the store's entries would be
  /// refetched early — the exact defeat this class exists to prevent.
  @override
  DateTime validUntil(ForecastProduct product, DateTime now) =>
      _inner.validUntil(product, now);

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    if (_switch.isStoreReadEnabled) {
      final fromStore = await _readStore(key);
      if (fromStore != null) {
        servedFromStore++;
        return fromStore;
      }
    }
    servedFromUpstream++;
    return _inner.fetch(key);
  }

  /// The store's answer for [key], or null to use the live path.
  Future<SourceFetchResult?> _readStore(RiverDataKey key) async {
    try {
      final snap = await _db
          .collection(kStoreCollection)
          .doc(key.storageKey)
          // Local persistence only. See the note at the top of this file.
          .get(const GetOptions(source: Source.cache));

      if (!snap.exists) return null;

      // The same decoder the listener uses, so a document the listener would
      // reject cannot enter through this door instead. Schema mismatches and
      // id/content disagreements are discarded, never guessed at.
      final entry = StoreSubscriptionService.decodeDocument(
        snap.id,
        snap.data(),
      );
      if (entry == null) return null;

      // An expired document is not served. The store having gone quiet is
      // exactly when the live path must take over, and serving a stale value
      // silently is what Phase 7's trust model cannot survive.
      if (!entry.window.validUntil.isAfter(DateTime.now().toUtc())) {
        AppLogger.info(
          _tag,
          'store document ${snap.id} expired; using the live path',
        );
        return null;
      }

      return SourceFetchResult(
        payload: entry.payload,
        unit: entry.unit,
        runId: entry.runId,
      );
    } catch (e) {
      // A cache miss with no local persistence throws rather than returning an
      // empty snapshot. That is a normal outcome here, not an error worth
      // surfacing (guard 8).
      return null;
    }
  }
}
