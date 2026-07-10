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

  @override
  Future<void> ingest(RiverDataEntry entry) => _cache.put(entry);

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
        validUntil: source.validUntil(key.product, now),
      ),
      unit: result.unit,
      payload: result.payload,
    );
    await _cache.put(entry);
    return entry;
  }
}
