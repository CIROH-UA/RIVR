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
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
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
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now,
       _api = api,
       _forecastService = forecastService,
       _unitService = unitService,
       // Injected but deliberately UNUSED: `reachMetadata` must not geocode.
       // Holding the dependency is what makes that testable — a fake can
       // assert zero calls. The previous guard timed the fetch instead, and
       // review measured a real geocode returning in 86 ms, under the
       // threshold, so it could never have failed for the right reason.
       // ignore: unused_field
       _geocoder = geocoder;

  final DateTime Function() _now;
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
  /// How long an answer carrying no readable points is held before we ask
  /// upstream again.
  ///
  /// A JUDGEMENT, not a measurement, and the reasoning is the point. NOAA
  /// answers 200 with the requested section absent as a per-request lottery
  /// inside a daily window: 3 full responses of 14 for one reach within five
  /// seconds while the window was open, and 0 of 700 across every production
  /// reach once it had shut (2026-11-03). So asking again soon is worth
  /// something, and asking again immediately is not.
  ///
  /// The number has to sit between two failures that have both happened here:
  ///
  /// * Hold the empty answer for the product's full window (6 hours for
  ///   medium and long range) and one unlucky request means an empty 10-day
  ///   panel all morning with no further attempt. That was the defect.
  /// * Hold it for nothing at all and every read refetches. Reads are not a
  ///   poll, but the forecast page alone reads each product more than once
  ///   per open (load, watch, and a re-decode on a unit change), so "cache
  ///   nothing" turned one page open into a climbing count of calls against
  ///   an endpoint that is already failing.
  ///
  /// Fifteen minutes stops the within-session repeat and still asks four
  /// times an hour while a user has the app open.
  static const Duration emptySectionRetry = Duration(minutes: 15);

  /// Whether a forecast payload carries anything the app can render.
  ///
  /// Phase 7 made silence a positive claim that the value on screen is
  /// current, so this is what decides whether an answer gets its product's
  /// full window or the short one above. Two ways to arrive at nothing, both
  /// real: NOAA serves a 200 with the requested section absent for medium and
  /// long range most of the time, and a single unreadable point used to
  /// discard the whole series around it.
  ///
  /// Deliberately asks "is there anything here at all" rather than naming a
  /// section per product. Which section answers a product is
  /// `ForecastValues`' decision, and a copy of that mapping here would be a
  /// reimplementation drifting out of step with the one the decoder uses.
  static bool _hasUsableSeries(Map<String, dynamic> payload) {
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

      // EVERY sub-map. Short range and analysis assimilation are
      // deterministic and keep their points under `series`; medium and long
      // range are ENSEMBLES and keep theirs under `mean`, `member1` and so
      // on. An earlier version looked under `series` alone, which meant no
      // medium or long range payload could ever satisfy it — it only looked
      // correct because an untrimmed payload always carried a deterministic
      // short range for it to find instead.
      //
      // `section` itself is included because a malformed payload can put the
      // points one level up; `section['series']` is NOT listed separately,
      // because `section.values` already covers it and an independent review
      // identified that term as dead.
      for (final candidate in [section, ...section.values]) {
        if (candidate is! Map<String, dynamic>) continue;
        if (candidate['data'] is! List) continue;
        try {
          if (ForecastSeriesDto.fromJson(candidate).toEntity().isNotEmpty) {
            return true;
          }
        } catch (_) {
          // Unreadable shape. Try the next candidate, then the next section.
        }
      }
    }

    return false;
  }

  /// The window an answer for [key] deserves: the product's publish schedule
  /// when it carries data, [emptySectionRetry] when it does not.
  ///
  /// Returning a window rather than throwing is a correction. The first
  /// version of this refused an empty answer by throwing, so that nothing
  /// was cached and nothing claimed to be current — and an independent review
  /// measured what that actually did on screen. `ReachDataProvider` turns any
  /// exception from a section read into `SectionLoadState.error`, which
  /// renders RED, "Something went wrong loading the medium range forecast.
  /// Pull down to retry." Nothing had gone wrong in the app, pulling down
  /// could not help, and `outOfSync` put the app-wide stale banner over the
  /// favourites page for half an hour. Measured on every CONUS reach that
  /// answered: medium and long range are empty 10 of 10 right now, so that
  /// was the normal case, not an edge.
  ///
  /// `SectionLoadState.empty` already exists for exactly this and renders
  /// orange, "temporarily unavailable, this usually resolves on its own" —
  /// which is true. Caching the empty answer briefly gets that state for
  /// free, because the entry decodes to a section with no points, and keeps
  /// the honest half of the original fix: the answer expires in minutes
  /// instead of being held for six hours as a confirmed current value.
  DateTime? _windowFor(RiverDataKey key, Map<String, dynamic> payload) {
    if (_hasUsableSeries(payload)) return null; // repository's own schedule
    AppLogger.warning(
      'NwmDataSource',
      'upstream served no readable points for ${key.reachId}/'
          '${key.product.name} — holding the empty answer '
          '${emptySectionRetry.inMinutes} min, not its publish window',
    );
    return _now().toUtc().add(emptySectionRetry);
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
        return SourceFetchResult(
          payload: aaPayload,
          unit: _unitOf(aaPayload),
          // Current flow is derived from the short_range series
          // (fetchCurrentFlowOnly fetches exactly that), so its run IS that
          // section's run.
          runId: _runIdOf(aaPayload, 'shortRange'),
          validUntil: _windowFor(key, aaPayload),
        );
      case ForecastProduct.shortRange:
        final shortPayload = await _api.fetchForecast(
          key.reachId,
          'short_range',
        );
        return SourceFetchResult(
          payload: shortPayload,
          unit: _unitOf(shortPayload),
          runId: _runIdOf(shortPayload, 'shortRange'),
          validUntil: _windowFor(key, shortPayload),
        );
      case ForecastProduct.mediumRange:
        final mediumPayload = await _api.fetchForecast(
          key.reachId,
          'medium_range',
        );
        return SourceFetchResult(
          payload: mediumPayload,
          unit: _unitOf(mediumPayload),
          runId: _runIdOf(mediumPayload, 'mediumRange'),
          validUntil: _windowFor(key, mediumPayload),
        );
      case ForecastProduct.longRange:
        final longPayload = await _api.fetchForecast(key.reachId, 'long_range');
        return SourceFetchResult(
          payload: longPayload,
          unit: _unitOf(longPayload),
          runId: _runIdOf(longPayload, 'longRange'),
          validUntil: _windowFor(key, longPayload),
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
