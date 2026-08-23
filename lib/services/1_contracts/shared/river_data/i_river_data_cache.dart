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
  /// Prepare disk storage: create the directory, discard entries of
  /// unrecognised schema versions, load the persisted pins. Runs lazily from
  /// the first get/put/pin-push — nothing needs to call it directly.
  Future<void> initialize();

  bool get isReady;

  /// Current entry for [key] (memory, hydrating from disk on a miss), or null.
  /// Returns regardless of freshness — the caller inspects `entry.window`.
  Future<RiverDataEntry?> get(RiverDataKey key);

  /// Store/replace the entry for its key, updating memory, disk, and observers.
  Future<void> put(RiverDataEntry entry);

  /// Observe the entry for [key]. Seeded with the current in-memory value (or
  /// null), updated on every [put]/[evict]/retention eviction/[clear], and
  /// seeded again when a disk read hydrates the key. Backs
  /// `ValueListenableBuilder`. Object identity is stable for a key while
  /// anything is listening.
  ValueListenable<RiverDataEntry?> listenable(RiverDataKey key);

  /// Declare which reaches must never be evicted by the retention cap — the
  /// user's favourites (ADR 0011 Phase 2). The favourites provider pushes this
  /// whenever membership changes; ids are reach ids, source-agnostic, because
  /// pinning the id in one source and evicting it in another would be
  /// indistinguishable from a bug to the user.
  void setPinnedReaches(Set<String> reachIds);

  /// Remove a single key from memory, disk, and observers.
  Future<void> evict(RiverDataKey key);

  /// Drop everything — entries, observers' values, AND the pinned set with
  /// its persisted file (pins belong to the account being cleared, and the
  /// empty set counts as this session's pin declaration so the old file
  /// cannot resurrect it). Called on every identity change: signOut,
  /// deleteAccount, and the auth-state listener's revoked-token path.
  Future<void> clear();
}
