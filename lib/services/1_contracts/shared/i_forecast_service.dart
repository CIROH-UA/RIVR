// lib/services/1_contracts/shared/i_forecast_service.dart

import 'package:rivr/models/1_domain/shared/reach_data.dart';

export 'package:rivr/models/1_domain/features/forecast/reach_details_data.dart';

/// The surviving sliver of the old forecast-loading contract.
///
/// ADR 0011 Phase 3 deleted everything else: the phased load methods, the
/// bundle (`loadReachDetailsData`/`reachSummary`), the value helpers (moved to
/// `ForecastValues`, pure), and the cache-clearing hooks (the caches are
/// gone). Every surface reads through `IRiverDataRepository`; the one thing a
/// data source still needs from this layer is the cheap reach-info fetch that
/// backs the `reachMetadata` product.
abstract class IForecastService {
  /// Basic reach info only — name and coordinates, no flow, no series, no
  /// geocoding. Backs `NwmDataSource`'s `reachMetadata` product.
  Future<ReachData> loadBasicReachInfo(String reachId);
}
