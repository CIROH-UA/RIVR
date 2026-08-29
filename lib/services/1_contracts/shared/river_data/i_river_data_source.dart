// lib/services/1_contracts/shared/river_data/i_river_data_source.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';

/// The result of a single source fetch: the raw JSON [payload] plus the flow
/// [unit] its values are in. The repository stamps this into a `RiverDataEntry`
/// (with a publish-aligned `FreshnessWindow`) and converts [unit] -> the user's
/// display unit at read time.
class SourceFetchResult {
  final Map<String, dynamic> payload;
  final String unit;

  /// The upstream model run this data came from — NWM's `referenceTime`,
  /// GEOGLOWS's forecast date — when the source can supply one (ADR 0011
  /// Phase 2: entries record their run so supersession is decidable from the
  /// stored data, without re-deriving anything from the network).
  final String? runId;

  /// The freshness window this value ALREADY carries, when the source knows it
  /// better than the repository can compute it.
  ///
  /// Normally null: a live fetch happened now, so the repository derives the
  /// window from the source's publish schedule and the read clock. But a value
  /// served from the ADR 0011 cloud store was fetched by the server at some
  /// earlier time and carries the window the server stamped. Recomputing it
  /// from the READ clock silently extends it — for the 30-day static products
  /// a name fetched 29 days ago would be given another 30, so the same
  /// document has two different expiries depending on which path served it.
  /// Review round 3, non-blocking 5.
  final DateTime? validUntil;

  /// When the value was ACTUALLY pulled from upstream, when the source knows
  /// it better than the repository can.
  ///
  /// Exactly the same argument as [validUntil] above, applied to the other
  /// half of the window — and it had to be made twice, because the first time
  /// only `validUntil` was carried across. Phase 7's re-review found the
  /// consequence: a value served from the cloud store was being stamped
  /// `fetchedAt: now` by the repository, so the hold clock reset on every
  /// device read and a document the SERVER had been holding for fourteen
  /// hours looked freshly fetched.
  ///
  /// That defeated the whole guard it was added for. `fetchedAt` is what
  /// answers "how long has nobody actually checked?" — the server never moves
  /// it when it extends a window, precisely so it stays honest — and the
  /// client must not move it either.
  ///
  /// Null for a genuine live fetch, which really did happen now.
  final DateTime? fetchedAt;

  const SourceFetchResult({
    required this.payload,
    required this.unit,
    this.runId,
    this.validUntil,
    this.fetchedAt,
  });
}

/// One data source (NWM, GEOGLOWS, ...) behind a uniform contract (ADR 0001,
/// decision D4). Adding a source = implement this + register it in the
/// `SourceRegistry`; nothing else in the data layer changes.
///
/// A source knows three things: which [ForecastSource] it is, which
/// [ForecastProduct]s it can serve, and — crucially — [validUntil], its own
/// publish schedule (this is what makes the cache's TTL publish-aligned rather
/// than an arbitrary global timer). Sources are stateless fetchers; caching,
/// deduplication, and stale-while-revalidate live in the repository.
abstract class IRiverDataSource {
  ForecastSource get source;

  Set<ForecastProduct> get supportedProducts;

  /// When the upstream could next possibly have published new data for
  /// [product], given [now]. Drives `FreshnessWindow.validUntil`.
  DateTime validUntil(ForecastProduct product, DateTime now);

  /// Fetch [key]'s current data. Throws if the product is unsupported.
  Future<SourceFetchResult> fetch(RiverDataKey key);
}
