// lib/services/4_infrastructure/river_data/river_data_repository.dart

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
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

  @override
  Future<RiverDataEntry?> read(RiverDataKey key) async {
    final cached = await _cache.get(key);

    if (cached != null && cached.isFreshAt(_now())) {
      return cached; // fresh — no network
    }

    if (cached != null) {
      // Stale — serve immediately, revalidate in the background.
      unawaited(
        _fetchAndCache(key).then(
          (_) {},
          onError: (Object e, StackTrace s) =>
              AppLogger.error(_tag, 'Background revalidate failed for $key', e),
        ),
      );
      return cached;
    }

    // Miss — must fetch (errors propagate to the caller).
    return _fetchAndCache(key);
  }

  @override
  Future<RiverDataEntry?> refresh(RiverDataKey key) => _fetchAndCache(key);

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
    final next = (_ingesting[k] ?? Future<void>.value())
        .then((_) => _ingestLocked(entry));
    _ingesting[k] = next.catchError((Object _) {});
    return next.whenComplete(() {
      if (identical(_ingesting[k], next)) _ingesting.remove(k);
    });
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
        fetchedAt: now,
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
    return entry;
  }
}
