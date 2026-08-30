// lib/models/1_domain/shared/river_data/nwm_domain.dart
//
// ADR 0011 Phase 9. The National Water Model is not one model on one schedule,
// and every freshness window in this app was written as though it were.
//
// **What was wrong.** `NwmDataSource.validUntil` stamped `shortRange` as
// expiring at the next top of the hour, because CONUS short range publishes
// hourly. Puerto Rico's publishes every six hours and Hawaii's every twelve.
// So for an island river the document expired eleven times before any new data
// could exist, and each expiry sent the device back upstream to be handed the
// identical run. That is the Phase 5 dead-air bug — a value marked stale while
// still being the newest that exists anywhere — except per-domain, and much
// larger: 15 minutes an hour became 11 hours out of 12.
//
// **Measured 2026-08-30, from NOAA's own production directory listing**
// (`nomads.ncep.noaa.gov/pub/data/nccf/com/nwm/prod/nwm.<YYYYMMDD>/<product>/`,
// counting the distinct `tNNz` run hours present that day). Not inferred from
// documentation, and not assumed:
//
//   short_range              t00..t14z, every hour   -> CONUS, hourly
//   short_range_puertorico   t00z t06z t12z          -> 6-hourly
//   short_range_hawaii       t00z t12z               -> 12-hourly
//   short_range_alaska       t00z t03z t06z t09z t12z -> 3-hourly
//   analysis_assim_hawaii    t00..t14z               -> hourly
//   analysis_assim_alaska    t00..t14z               -> hourly
//
// Corroborated at the API the app actually calls: NWPS reach `800000010`
// (Oahu, 21.495/-158.113) reported its short-range `referenceTime` as
// `2026-08-30T00:00:00Z` at 15:16Z — fifteen hours old and still current,
// which rules out hourly on its own.
//
// **Islands also have FEWER products.** That same Oahu reach exposes only
// `["analysis_assimilation", "short_range"]`, where CONUS reach `23021904`
// exposes five. There is no medium or long range for Hawaii or Puerto Rico at
// all — `medium_range_alaska` and `long_range_alaska` are HTTP 403 on NOMADS,
// and NWPS simply omits them from the island reach's product list.
//
// **Alaska is deliberately absent from this file.** Its cadences are recorded
// above because they were measured, but the app cannot reach an Alaska river:
// `byu-hydroinformatics.nwm-channels-v3` returns 404 for Fairbanks, Juneau,
// Kenai and Anchorage at both z5 and z7, so there is no line on the map to
// tap. Adding an Alaska branch here would be untestable code for a case that
// cannot occur, and would read to a later maintainer as though it had been
// verified. If Alaska is ever tiled, this is the file to change, and 3 hours
// is the number.

import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';

/// Which National Water Model domain a reach belongs to.
///
/// Only the distinction that changes a publish schedule is modelled. Hawaii
/// and Puerto Rico are one value on purpose — see [islandShortRangeCycleHours].
enum NwmDomain {
  /// The contiguous United States. Hourly short range, 6-hourly medium/long.
  conus,

  /// Hawaii or Puerto Rico. Slower short range, and no medium or long range.
  island,
}

/// Lowest NHDPlus COMID in the island band, inclusive.
///
/// The same band the reach-detail sheet already uses to decide between a
/// 5-day and a 48-hour forecast horizon. Sharing one definition is the point:
/// two independent copies of "is this an island reach" would drift.
const int islandComidMin = 800000000;

/// Highest NHDPlus COMID in the island band, inclusive.
const int islandComidMax = 921999999;

/// How often island short range publishes, in hours.
///
/// **Six, not twelve, and the reason matters.** Hawaii publishes 12-hourly and
/// Puerto Rico 6-hourly, and they share one COMID band, so a reach id cannot
/// tell them apart. One of the two numbers has to cover both.
///
/// Twelve would be the "efficient" choice and is the wrong one: it would hold
/// a Puerto Rico forecast for six hours after a newer run existed, which is
/// showing someone stale water — the failure this whole ADR is against. Six
/// costs Hawaii one redundant refetch per run and never shows an old value.
/// When the two options are "waste a fetch" and "show the wrong number", the
/// wasted fetch wins every time.
const int islandShortRangeCycleHours = 6;

/// Which domain [reachId] is in.
///
/// Unparseable ids fall back to [NwmDomain.conus], which is the safe direction:
/// CONUS has the SHORTEST windows, so a misclassified reach refetches more
/// often than it needs to rather than holding a value past its run.
NwmDomain nwmDomainOf(String reachId) {
  final id = int.tryParse(reachId);
  if (id == null) return NwmDomain.conus;
  return id >= islandComidMin && id <= islandComidMax
      ? NwmDomain.island
      : NwmDomain.conus;
}

/// NWM products NOAA does not serve for Hawaii or Puerto Rico.
///
/// **Measured, not assumed:** NWPS reach `800000010` (Oahu) reports
/// `streamflow: ["analysis_assimilation", "short_range"]` where a CONUS reach
/// reports five, and NOMADS has no `medium_range_hawaii` or
/// `long_range_puertorico` directory at all.
///
/// Mirrors `ISLAND_UNAVAILABLE` in `functions/src/store-upstream.ts`.
const Set<ForecastProduct> islandUnavailable = {
  ForecastProduct.mediumRange,
  ForecastProduct.longRange,
};

/// Whether [product] exists at all for [reachId].
///
/// Phase 9 measured that the islands have no medium or long range and then
/// acted on it only on the SERVER — `canFetch` there, and the hold-cap tables.
/// The client kept offering all five products to every reach, so an island
/// favourite would subscribe to two store documents that can never exist:
/// listeners that can never fire, which `kStoredProducts` exists to avoid.
///
/// "Fixed on one side of a language boundary is not fixed" was written into a
/// commit message on 2026-08-30 and then done again, the same day, in the
/// same change. This is the other side.
bool nwmProductExistsFor(ForecastProduct product, String reachId) =>
    !(nwmDomainOf(reachId) == NwmDomain.island &&
        islandUnavailable.contains(product));
