// lib/services/1_contracts/shared/river_data/i_river_data_repository.dart

import 'package:flutter/foundation.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';

/// The single source of truth for river data (ADR 0001, decision D1).
///
/// Every surface reads through this repository instead of calling a source API
/// or a cache directly. It owns:
///  - **de-duplication** — concurrent requests for the same key share one fetch,
///  - **stale-while-revalidate** — fresh cache served with no network; stale
///    cache served immediately while a background refresh runs (decision D3),
///  - **fan-out** — [watch] hands back the cache's per-key observable, so one
///    fetch updates every widget bound to that key.
///
/// Entries are returned **unit-tagged** (`entry.unit`); the caller converts the
/// payload's flow values to the user's display unit at the consume boundary,
/// where the product schema is known. That keeps this repository agnostic of
/// NWM vs GEOGLOWS payload shapes.
abstract class IRiverDataRepository {
  /// Best available value for [key]: fresh cache, or stale cache + background
  /// revalidate, or a fetch on a miss. Returns null only if a miss also fails.
  Future<RiverDataEntry?> read(RiverDataKey key);

  /// Force a network fetch regardless of freshness (pull-to-refresh).
  Future<RiverDataEntry?> refresh(RiverDataKey key);

  /// Observe [key]; binding widgets rebuild when its entry changes. Also kicks
  /// off a [read] so the value populates/revalidates.
  ValueListenable<RiverDataEntry?> watch(RiverDataKey key);

  /// Insert a value produced outside the normal fetch path (e.g. an FCM push
  /// payload) so the UI reflects it without a network call (step 6).
  Future<void> ingest(RiverDataEntry entry);
}
