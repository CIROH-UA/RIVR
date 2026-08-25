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
// **It reads the local cache FIRST, then the server.** The first version read
// `Source.cache` only, which review round 3 showed still failed guard 1 on the
// case the guard is written about: a genuinely cold cache — first install,
// cleared data, an eviction — has no document, so the read missed and the
// device called NOAA. Guard 3 says "cold device cache" in as many words, and
// the ADR's *You are done when* says "within 3 seconds of a cold start", so
// cold is in scope, not an excused edge case.
//
// Two reads, in this order, for reasons that do not collapse into one:
//   - `Source.cache` first: a warm favourite is instant, works with the
//     network off (guard 4), and costs NO billed read. This is the steady
//     state and it is the common case.
//   - `Source.server` on a miss: a cold favourite is fetched from the store
//     rather than from NOAA. It is a Firestore read, not an upstream call, so
//     guard 1 holds — the guard is about upstream, which is what costs money,
//     rate limit and latency.
//
// **The cost this accepts:** a NON-favourite now costs one Firestore read per
// product that misses locally, and returns not-found. Tapping an unfavourited
// reach on the map is ~3 such reads. At the ADR's current scale that is
// nothing against a 50,000/day free tier, and it buys the phase's central
// guard. If it ever stops being nothing, the lever is to gate the server read
// on the subscription's watch set — the favourites are known — rather than to
// go back to cache-only.
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
        _injectedDb = firestore;

  static const String _tag = 'STORE_SOURCE';

  final IRiverDataSource _inner;
  final StoreReadSwitch _switch;
  final FirebaseFirestore? _injectedDb;

  /// Lazy, so constructing this does not require an initialised Firebase app.
  /// See the note on StoreReadSwitch._rc.
  FirebaseFirestore get _db => _injectedDb ?? FirebaseFirestore.instance;

  /// Store reads that produced a usable entry. Exposed for the guards — this
  /// is the number that says an upstream call did NOT happen.
  int servedFromStore = 0;

  /// Fetches that fell through to the wrapped source.
  int servedFromUpstream = 0;

  /// Store reads that threw. A local miss is normal and counts here too, so
  /// this is a diagnostic signal rather than an error count — but a number
  /// that climbs while [servedFromStore] stays at zero means the store is
  /// unreachable, not merely cold.
  int storeReadFailures = 0;

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
    // Local first — instant, free, and works offline.
    final cached = await _readStoreFrom(key, Source.cache);
    if (cached != null) return cached;

    // Cold cache. Ask the store's server rather than NOAA: this is what makes
    // guard 1 hold on a first install. See the note at the top of this file.
    return _readStoreFrom(key, Source.server);
  }

  Future<SourceFetchResult?> _readStoreFrom(
    RiverDataKey key,
    Source source,
  ) async {
    try {
      final snap = await _db
          .collection(kStoreCollection)
          .doc(key.storageKey)
          .get(GetOptions(source: source));

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
        // The SERVER's window, not a fresh one computed from this read. The
        // document was fetched upstream when the server fetched it, and
        // re-stamping it here would let each device extend its life.
        validUntil: entry.window.validUntil,
      );
    } catch (e) {
      // A local miss throws rather than returning an empty snapshot, so this
      // is a NORMAL outcome for Source.cache and never worth surfacing
      // (guard 8). It is not normal for Source.server, where it means offline
      // or a rules failure.
      //
      // Counted and logged either way. Round 3, non-blocking 3: this catch was
      // silent, which made every decode bug, permission error and plugin fault
      // indistinguishable from an ordinary cache miss — in a project whose
      // stated non-negotiable is that these paths fail silently.
      storeReadFailures++;
      if (source == Source.server) {
        AppLogger.info(
          _tag,
          'store server read failed for ${key.storageKey}; '
          'using the live path: $e',
        );
      }
      return null;
    }
  }
}
