// lib/services/1_contracts/shared/river_data/i_river_data_cache.dart

import 'package:flutter/foundation.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';

/// The shared, source-agnostic river-data cache (ADR 0001, decision D2).
///
/// It is intentionally *dumb storage*: it stores and returns entries keyed by
/// [RiverDataKey], but it does NOT decide fresh-vs-stale or trigger fetches —
/// that stale-while-revalidate policy lives in the repository (decision D3), so
/// there is exactly one place that owns it. The cache's only jobs are:
///  - persist entries (in-memory for instant fan-out, disk to survive restarts),
///  - hand back the current entry (with its [FreshnessWindow]) for a key,
///  - notify observers of a key when its entry changes, so one fetch's result
///    updates every widget bound to that key.
abstract class IRiverDataCache {
  /// Prepare disk storage. Safe to call once at startup.
  Future<void> initialize();

  bool get isReady;

  /// Current entry for [key] (memory, hydrating from disk on a miss), or null.
  /// Returns regardless of freshness — the caller inspects `entry.window`.
  Future<RiverDataEntry?> get(RiverDataKey key);

  /// Store/replace the entry for its key, updating memory, disk, and observers.
  Future<void> put(RiverDataEntry entry);

  /// Observe the entry for [key]. Seeded with the current in-memory value (or
  /// null) and updated on every [put]/[evict]. Backs `ValueListenableBuilder`.
  ValueListenable<RiverDataEntry?> listenable(RiverDataKey key);

  /// Remove a single key from memory, disk, and observers.
  Future<void> evict(RiverDataKey key);

  /// Drop everything (e.g. on sign-out).
  Future<void> clear();
}
