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

  const SourceFetchResult({required this.payload, required this.unit});
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
