// lib/services/4_infrastructure/river_data/river_data_repository.dart

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/river_data/hold_policy.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';

/// Source-of-truth implementation over [IRiverDataCache] + [SourceRegistry].
/// See [IRiverDataRepository] for the contract. A [clock] is injectable so the
/// freshness logic is deterministically testable.
class RiverDataRepository implements IRiverDataRepository {
  RiverDataRepository({
    required IRiverDataCache cache,
    required SourceRegistry registry,
    DateTime Function()? clock,
  }) : _cache = cache,
       _registry = registry,
       _now = clock ?? DateTime.now;

  static const String _tag = 'RIVER_DATA_REPO';

  final IRiverDataCache _cache;
  final SourceRegistry _registry;
  final DateTime Function() _now;

  /// One in-flight fetch per key, so concurrent readers share a single request.
  final Map<String, Future<RiverDataEntry>> _inFlight = {};

  final ValueNotifier<bool> _outOfSync = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get outOfSync => _outOfSync;

  /// The keys we currently cannot supply a confirmed-current value for.
  ///
  /// **Per key, not one global latch.** Review round 1 found the latch version
  /// wrong in both directions at once: it was raised by whichever key failed
  /// and cleared by ANY key succeeding, so with several favourites refreshing
  /// concurrently one permanently-failing reach made the banner flap in and
  /// out on a 260 ms animation, while a successful `returnPeriods` fetch for a
  /// different river silently cancelled a genuine stall on the flow the user
  /// was reading. Keeping the set makes both impossible: the warning stands
  /// while, and only while, something is actually unresolved.
  final Set<String> _unconfirmed = {};

  /// Phase 7 makes this the whole of the app's honesty about freshness: with
  /// the timestamps gone, silence is a claim that the numbers are current, and
  /// this is the only thing entitled to withdraw that claim.
  void _markUnconfirmed(RiverDataKey key) {
    if (_unconfirmed.add(key.storageKey)) _sync();
  }

  void _markConfirmed(RiverDataKey key) {
    if (_unconfirmed.remove(key.storageKey)) _sync();
  }

  /// Judge a value we are about to serve or store.
  ///
  /// Called wherever an entry is ADOPTED — a fresh cache hit, a completed
  /// fetch, a pushed store document — because "is this held too long?" is a
  /// property of the value, not of the door it came through. The re-review
  /// found the first version asking the question only on a cache hit, so a
  /// store document that arrived already fourteen hours old was adopted,
  /// rendered and marked confirmed, and stayed unquestioned until some later
  /// read happened to look.
  void _judge(RiverDataKey key, RiverDataEntry entry) {
    if (heldTooLong(
      product: key.product,
      fetchedAt: entry.window.fetchedAt,
      now: _now(),
    )) {
      _markUnconfirmed(key);
    } else {
      _markConfirmed(key);
    }
  }

  void _sync() {
    final value = _unconfirmed.isNotEmpty;
    if (_outOfSync.value != value) _outOfSync.value = value;
  }

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    final cached = await _cache.get(key);

    if (cached != null && cached.isFreshAt(_now())) {
      // In-window — but that is not the whole question, and Phase 7's review
      // found the gap. A stored document's `validUntil` is extended every hour
      // that upstream has not published, so it can read "fresh" indefinitely
      // about water nobody has refetched. `fetchedAt` is never moved by an
      // extension, so it is the honest record — and past the product's hold
      // cap the SERVER stops extending and lets the document expire. The
      // client stops vouching for it at the same instant, using the same
      // constant.
      _judge(key, cached);
      return cached; // fresh — no network
    }

    if (cached != null) {
      // Stale — serve immediately, revalidate in the background.
      unawaited(
        _fetchAndCache(key).then(
          (_) {},
          onError: (Object e, StackTrace s) {
            AppLogger.error(_tag, 'Background revalidate failed for $key', e);
            // The user is now looking at a value past its window that we
            // could not replace. Phase 7 took away the timestamp that would
            // have let them see that for themselves.
            _markUnconfirmed(key);
          },
        ),
      );
      return cached;
    }

    // Miss — must fetch (errors propagate to the caller).
    //
    // This branch counts too, and review round 1 found it did not. The
    // repository having nothing does NOT mean the screen is empty: the
    // favourites card renders `lastKnownFlow`, restored from SharedPreferences
    // on a cold start with no age check at all. So after any cache wipe —
    // signing out and back in, or the Phase 5 kill switch flipping ON to OFF,
    // which is exactly the thing you do BECAUSE upstream is misbehaving — a
    // failing fetch leaves yesterday's number on screen. Before Phase 7 that
    // card said "1d ago" next to it; now nothing does unless this fires.
    try {
      return await _fetchAndCache(key);
    } catch (_) {
      _markUnconfirmed(key);
      rethrow;
    }
  }

  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) async {
    try {
      return await _fetchAndCache(key);
    } catch (_) {
      // A pull-to-refresh that fails is only a freshness problem if what
      // stays on screen is actually past its window. Failing while the cached
      // value is still in-window has cost the user nothing, and warning there
      // is the noise that teaches people to ignore the strip.
      //
      // Review round 1 found this path raised nothing at all: a user could
      // pull to refresh on data hours past its window, watch it fail, and get
      // no indication — on the very gesture that asks "is this current?".
      final cached = await _cache.get(key);
      if (cached == null || !cached.isFreshAt(_now())) {
        _markUnconfirmed(key);
      }
      rethrow;
    }
  }

  @override
  ValueListenable<RiverDataEntry?> watch(RiverDataKey key) {
    unawaited(
      read(key).then(
        (_) {},
        onError: (Object e, StackTrace s) =>
            AppLogger.error(_tag, 'watch read failed for $key', e),
      ),
    );
    return _cache.listenable(key);
  }

  /// Accept a value pushed in from outside (the ADR 0011 cloud store).
  ///
  /// **Supersession, mirroring the server's own `shouldWrite`** (Phase 4
  /// guard 6, "overlapping runs cannot write backwards"). Round 4, B3: this
  /// was an unconditional `_cache.put`, so a store document carrying an OLDER
  /// run replaced a fresher live-path value and `read` then served the older
  /// one — the user watching the flow go backwards. It is reachable two ways:
  /// the initial snapshot on attach delivers every watched document while
  /// `FavoritesProvider`'s 500 ms refresh-all routinely lands first, and in
  /// steady state between :00 and :20 past the hour the store still holds the
  /// previous run. The server refuses exactly this write; the client accepted
  /// it.
  ///
  /// An EXPIRED entry is refused too. Ingesting one would put a value in the
  /// cache that `read` immediately treats as stale and revalidates upstream —
  /// a guaranteed network call caused by the store, which is the opposite of
  /// what the store is for. `StoreBackedDataSource` already refuses expired
  /// documents at the other door; this closes the pair.
  /// Serialises [ingest] per key. Round 5, non-blocking 1: ingest became a
  /// read-modify-write (get, compare runs, put) and `_onSnapshot` fires them
  /// unawaited per document, so two snapshots for the same key could both read
  /// the old value and the OLDER write could land last — reintroducing exactly
  /// the backwards-walk the supersession check exists to stop.
  final Map<String, Future<void>> _ingesting = {};

  @override
  Future<void> ingest(RiverDataEntry entry) {
    final k = entry.key.storageKey;
    final chained = (_ingesting[k] ?? Future<void>.value())
        .then((_) => _ingestLocked(entry));
    // Kept separately from `chained`: the map holds the error-swallowing
    // wrapper so one bad ingest cannot poison the chain, while the CALLER gets
    // the real future. Round 6 found the previous cleanup compared the wrapper
    // with `chained` — never identical — so the entry was never removed and
    // the map grew one completed chain per key for the process lifetime. Small
    // and bounded, but it was dead code that read as live.
    final guarded = chained.catchError((Object _) {});
    _ingesting[k] = guarded;
    unawaited(guarded.whenComplete(() {
      if (identical(_ingesting[k], guarded)) _ingesting.remove(k);
    }));
    return chained;
  }

  Future<void> _ingestLocked(RiverDataEntry entry) async {
    if (!entry.window.validUntil.isAfter(_now().toUtc())) {
      AppLogger.info(
        _tag,
        'ignoring expired ingest for ${entry.key.storageKey}',
      );
      return;
    }

    final existing = await _cache.get(entry.key);
    if (!_supersedes(entry, existing)) {
      AppLogger.info(
        _tag,
        'ignoring ingest for ${entry.key.storageKey}: run ${entry.runId} does '
        'not supersede ${existing?.runId}',
      );
      return;
    }
    await _cache.put(entry);
    // A store document is current data arriving by a different door. Round 1:
    // only `_doFetch` cleared the flag, and store documents never go through
    // it — they come from the Firestore listener. So a phone that came back
    // from a tunnel got correct numbers pushed to it, repainted them, and then
    // kept "These numbers may not be current" over the top of them: every
    // later read found the cache fresh and never fetched, so nothing cleared
    // it until the next expiry AND a live fetch.
    _judge(entry.key, entry);
  }

  /// Whether [incoming] may replace [existing]. Same ordering the server uses.
  static bool _supersedes(RiverDataEntry incoming, RiverDataEntry? existing) {
    if (existing == null) return true;

    final had = existing.runId;
    final has = incoming.runId;

    // Both identified: only a strictly newer run wins. Equal runs are the same
    // data, so rewriting would churn observers for nothing.
    if (had != null && has != null) return _isRunNewer(has, had);
    // Losing run identity loses the ability to order anything afterwards.
    if (had != null && has == null) return false;
    return true;
  }

  static bool _isRunNewer(String candidate, String current) {
    final a = DateTime.tryParse(candidate);
    final b = DateTime.tryParse(current);
    if (a != null && b != null) return a.isAfter(b);
    // Non-ISO run formats (GEOGLOWS uses a date string) still order sensibly.
    return candidate.compareTo(current) > 0;
  }

  Future<RiverDataEntry> _fetchAndCache(RiverDataKey key) {
    return _inFlight.putIfAbsent(key.storageKey, () {
      // Block body (returns void): if this returned Map.remove's value — the
      // in-flight Future itself — whenComplete would wait on it and deadlock.
      return _doFetch(key).whenComplete(() {
        _inFlight.remove(key.storageKey);
      });
    });
  }

  Future<RiverDataEntry> _doFetch(RiverDataKey key) async {
    final source = _registry.forKey(key);
    final now = _now();
    final result = await source.fetch(key);
    final entry = RiverDataEntry(
      key: key,
      window: FreshnessWindow(
        // The SOURCE's own fetch time wins when it has one — only the cloud
        // store supplies it, and only because the value really was pulled
        // upstream earlier, by the server. Stamping `now` unconditionally
        // reset the hold clock on every device read, which is what stopped
        // Phase 7's guard 3 from ever firing on store-served data.
        fetchedAt: result.fetchedAt ?? now,
        // The source's own window wins when it has one. Only the cloud store
        // supplies it, and only because its value was fetched earlier by the
        // server: recomputing from the read clock would extend the server's
        // expiry every time a device read it. Everything else passes null and
        // gets the publish-aligned window as before.
        validUntil: result.validUntil ?? source.validUntil(key.product, now),
      ),
      unit: result.unit,
      runId: result.runId,
      payload: result.payload,
    );
    await _cache.put(entry);
    // NOT an unconditional confirm: a store-served value can arrive already
    // older than its product's hold cap, and adopting it is exactly when that
    // must be noticed.
    _judge(key, entry);
    return entry;
  }
}
