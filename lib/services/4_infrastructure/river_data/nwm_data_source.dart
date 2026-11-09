// lib/services/4_infrastructure/river_data/nwm_data_source.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/nwm_domain.dart';
import 'package:rivr/models/1_domain/shared/river_data/publish_schedule.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/reach_metadata_payload.dart';
import 'package:rivr/services/3_datasources/shared/dtos/reach_data_dto.dart'
    show ForecastSeriesDto;

/// [IRiverDataSource] for the NOAA National Water Model (US). A thin adapter
/// over the NWM stack: each raw forecast product maps to one [INoaaApiService]
/// call, and `reachMetadata` goes through [IForecastService.loadBasicReachInfo]
/// for its reach-info cache. The composite `reachSummary` bundle was deleted in
/// Phase 3 — this source rejects it. Payloads are tagged with the unit they
/// were fetched in (consumers convert at decode).
class NwmDataSource implements IRiverDataSource {
  NwmDataSource({
    required INoaaApiService api,
    required IForecastService forecastService,
    required IFlowUnitPreferenceService unitService,
    required IGeocodingService geocoder,
  }) : _api = api,
       _forecastService = forecastService,
       _unitService = unitService,
       // Injected but deliberately UNUSED: `reachMetadata` must not geocode.
       // Holding the dependency is what makes that testable — a fake can
       // assert zero calls. The previous guard timed the fetch instead, and
       // review measured a real geocode returning in 86 ms, under the
       // threshold, so it could never have failed for the right reason.
       // ignore: unused_field
       _geocoder = geocoder;

  final INoaaApiService _api;
  final IForecastService _forecastService;
  final IFlowUnitPreferenceService _unitService;
  // ignore: unused_field
  final IGeocodingService _geocoder;

  /// Small slack so we don't invalidate the instant a cycle rolls over and
  /// refetch before the new run has actually published.
  static const Duration _skew = Duration(minutes: 5);

  @override
  ForecastSource get source => ForecastSource.nwm;

  @override
  Set<ForecastProduct> get supportedProducts => const {
    ForecastProduct.currentFlow,
    ForecastProduct.reachMetadata,
    ForecastProduct.shortRange,
    ForecastProduct.mediumRange,
    ForecastProduct.longRange,
    ForecastProduct.returnPeriods,
  };

  @override
  DateTime validUntil(
    ForecastProduct product,
    DateTime now, {
    required String reachId,
  }) {
    switch (product) {
      case ForecastProduct.currentFlow:
      case ForecastProduct.shortRange:
        // **`currentFlow` shares this branch because it IS short range.** Its
        // handler calls `fetchCurrentFlowOnly`, which is
        // `fetchForecast(reachId, 'short_range')`; its run id is read out of
        // the payload's `shortRange` section; and the server maps it to
        // `"short_range"` too. So its publish schedule is short range's, in
        // every domain.
        //
        // These two were split apart earlier on 2026-08-30, while this
        // product was still called `analysisAssimilation`, on a confident
        // comment arguing that analysis assimilation publishes hourly
        // everywhere. That is TRUE of NOAA's real analysis-assimilation
        // series (`analysis_assim_hawaii` ran t00z..t14z that day) and it is
        // not what this product fetches. The split put island documents back
        // on the CONUS hour — the exact defect the same change had just
        // removed, reintroduced under a misleading name within the hour.
        // Renaming the product is why this cannot happen a fourth time.
        //
        // Hourly for CONUS; 6-hourly for Hawaii and Puerto Rico. See
        // [NwmDomain] for the measurements and for why one number covers both
        // islands.
        return switch (nwmDomainOf(reachId)) {
          NwmDomain.conus => PublishSchedule.nextTopOfHour(now).add(_skew),
          NwmDomain.island => PublishSchedule.nextCycle(
            now,
            everyHours: islandShortRangeCycleHours,
          ).add(_skew),
        };
      case ForecastProduct.mediumRange:
      case ForecastProduct.longRange:
        // Every 6 hours (00/06/12/18Z).
        return PublishSchedule.nextCycle(now, everyHours: 6).add(_skew);
      case ForecastProduct.returnPeriods:
      case ForecastProduct.reachMetadata:
        // Static — thresholds don't change day to day, and a river's name and
        // coordinates don't change at all.
        return now.toUtc().add(const Duration(days: 30));
      case ForecastProduct.mediumRangeBlend:
      case ForecastProduct.geoglowsForecast:
      case ForecastProduct.geoglowsEnsemble:
      case ForecastProduct.reachSummary: // deleted in Phase 3
        throw ArgumentError('NWM does not support $product');
    }
  }

  /// Pull the model-run identity (`referenceTime`) out of [sectionKey]'s
  /// section of a raw NOAA payload — `series.referenceTime` for deterministic
  /// series, the first member's for ensembles. Null when the section carries
  /// none: not every product HAS a run, and inventing one would make
  /// supersession lie.
  ///
  /// Keyed by section, never first-found: `fetchForecast` falls back to the
  /// FULL multi-section response when the filtered call comes back empty, and
  /// round 6 proved the first-found version stamping mediumRange and longRange
  /// entries with shortRange's run — which advances hourly while theirs move
  /// 4×/day, so their recorded run flipped without their data moving.
  static String? _runIdOf(Map<String, dynamic> payload, String sectionKey) {
    final section = payload[sectionKey];
    if (section is! Map) return null;
    final series = section['series'];
    if (series is Map && series['referenceTime'] is String) {
      return series['referenceTime'] as String;
    }
    // Ensemble shape: members keyed inside the section.
    for (final member in section.values) {
      if (member is Map && member['referenceTime'] is String) {
        return member['referenceTime'] as String;
      }
    }
    return null;
  }

  /// The unit a converted forecast payload actually carries.
  ///
  /// Prefers the stamp the converter wrote. Falls back to the live
  /// preference only for payloads that carry no flow series at all, where
  /// the tag is not load-bearing.
  ///
  /// Reading the preference here used to be the ONLY source, captured before
  /// the await while the conversion read it again after. See
  /// `kConvertedUnitKey`.
  /// Throws when a forecast payload carries nothing the app can render.
  ///
  /// A payload with no readable points anywhere is not a successful fetch.
  /// It used to be stored as one: the entry got its normal window, was
  /// judged confirmed, and `outOfSync` stayed false — so the reach showed
  /// "No data" while the app positively claimed that nothing was current,
  /// and no later read retried.
  ///
  /// Two ways to arrive there, both real. NOAA serves a 200 with the
  /// requested section absent for medium and long range most of the time.
  /// And a single unreadable point used to discard the whole series around
  /// it (fixed in `ForecastSeriesDto._pointsOf`), which can still empty a
  /// series outright when every point is malformed.
  ///
  /// Deliberately asks "is there anything here at all" rather than naming a
  /// section per product. Which section answers a product is
  /// `ForecastValues`' decision, and a copy of that mapping here would be a
  /// reimplementation drifting out of step with the one the decoder uses.
  ///
  /// Phase 7 made silence a positive claim that the value on screen is
  /// current. This is what keeps that claim honest.
  void _requireUsableSeries(Map<String, dynamic> payload, RiverDataKey key) {
    const sections = [
      'analysisAssimilation',
      'shortRange',
      'mediumRange',
      'mediumRangeBlend',
      'longRange',
    ];

    for (final name in sections) {
      final section = payload[name];
      if (section is! Map<String, dynamic>) continue;

      // EVERY sub-map, not just `series`. Short range and analysis
      // assimilation are deterministic and keep their points under `series`;
      // medium and long range are ENSEMBLES and keep theirs under `mean`,
      // `member1`, `member2` and so on. The first version of this guard
      // looked at `series` and at the section itself, which meant no medium
      // or long range payload could ever satisfy it — and with the payload
      // trimmed to one product (backlog item 3) that would have refused
      // every daily and extended forecast the app has. It only looked
      // correct because an untrimmed payload always carried a deterministic
      // short range for it to find instead.
      final candidates = <dynamic>[section['series'], section, ...section.values];

      for (final candidate in candidates) {
        if (candidate is! Map<String, dynamic>) continue;
        if (candidate['data'] is! List) continue;
        try {
          // The REAL parser, not a count of raw entries. A section can be
          // structurally present and still decode to nothing: NOAA sends
          // points with a null flow, and those are dropped. Counting the raw
          // list would call that a success and cache an empty forecast as
          // current, which is the defect this guard exists for.
          if (ForecastSeriesDto.fromJson(candidate).toEntity().isNotEmpty) {
            return;
          }
        } catch (_) {
          // Unreadable shape. Try the next candidate, then the next section.
        }
      }
    }

    throw EmptyForecastSection(key.reachId, key.product.name);
  }

  String _unitOf(Map<String, dynamic> payload) =>
      (payload[kConvertedUnitKey] as String?) ?? _unitService.currentFlowUnit;

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    final unit = _unitService.currentFlowUnit;
    switch (key.product) {
      case ForecastProduct.reachMetadata:
        // The cheap half of the old reachSummary: no flow data, no forecast
        // series. Lets a surface title itself in isolation.
        // Deliberately does NOT geocode. An earlier version did, to preserve
        // the place name that `loadOverviewData` used to fill — but
        // `GeocodingService.reverseGeocode` catches internally and returns a
        // null map rather than throwing, so nothing bounded it except a 30 s
        // HTTP timeout. That put a second, unbounded network hop in front of
        // the one call this product exists to keep fast.
        //
        // The place name is decoration and is filled off the critical path by
        // the consumer (ADR 0011, geocoding off the critical path). `formattedLocation` here is
        // whatever the reach already knew.
        final reach = await _forecastService.loadBasicReachInfo(key.reachId);

        return SourceFetchResult(
          payload: ReachMetadataPayload.encode(
            ReachMetadata(
              riverName: reach.riverName,
              formattedLocation: reach.formattedLocation,
              latitude: reach.latitude,
              longitude: reach.longitude,
            ),
          ),
          // Nothing here is a flow value, so the stored unit is irrelevant —
          // recorded only to satisfy the entry contract.
          unit: unit,
        );
      case ForecastProduct.currentFlow:
        final aaPayload = await _api.fetchCurrentFlowOnly(key.reachId);
        _requireUsableSeries(aaPayload, key);
        return SourceFetchResult(
          payload: aaPayload,
          unit: _unitOf(aaPayload),
          // Current flow is derived from the short_range series
          // (fetchCurrentFlowOnly fetches exactly that), so its run IS that
          // section's run.
          runId: _runIdOf(aaPayload, 'shortRange'),
        );
      case ForecastProduct.shortRange:
        final shortPayload = await _api.fetchForecast(
          key.reachId,
          'short_range',
        );
        _requireUsableSeries(shortPayload, key);
        return SourceFetchResult(
          payload: shortPayload,
          unit: _unitOf(shortPayload),
          runId: _runIdOf(shortPayload, 'shortRange'),
        );
      case ForecastProduct.mediumRange:
        final mediumPayload = await _api.fetchForecast(
          key.reachId,
          'medium_range',
        );
        _requireUsableSeries(mediumPayload, key);
        return SourceFetchResult(
          payload: mediumPayload,
          unit: _unitOf(mediumPayload),
          runId: _runIdOf(mediumPayload, 'mediumRange'),
        );
      case ForecastProduct.longRange:
        final longPayload = await _api.fetchForecast(key.reachId, 'long_range');
        _requireUsableSeries(longPayload, key);
        return SourceFetchResult(
          payload: longPayload,
          unit: _unitOf(longPayload),
          runId: _runIdOf(longPayload, 'longRange'),
        );
      case ForecastProduct.returnPeriods:
        return SourceFetchResult(
          payload: {
            'returnPeriods': await _api.fetchReturnPeriods(key.reachId),
          },
          unit: unit,
        );
      case ForecastProduct.mediumRangeBlend:
      case ForecastProduct.geoglowsForecast:
      case ForecastProduct.geoglowsEnsemble:
      case ForecastProduct.reachSummary:
        // reachSummary DELETED in Phase 3: the bundle cost a 156 KB
        // medium-range fetch per favourites refresh and split current flow
        // across two cache entries. Every ex-reader is on the narrow products.
        throw ArgumentError('NWM does not support ${key.product}');
    }
  }
}

/// A forecast section came back with nothing renderable in it.
///
/// Distinct from a transport failure so logs and the sync banner can tell
/// "upstream served nothing" from "we could not reach upstream". Both mean
/// the same thing to the cache: do not store this and do not claim it is
/// current.
class EmptyForecastSection implements Exception {
  final String reachId;
  final String section;

  EmptyForecastSection(this.reachId, this.section);

  @override
  String toString() =>
      'EmptyForecastSection($reachId/$section): upstream returned no '
      'readable points — not cached, will retry';
}
