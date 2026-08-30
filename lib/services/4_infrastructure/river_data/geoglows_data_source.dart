// lib/services/4_infrastructure/river_data/geoglows_data_source.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/features/forecast/i_geoglows_api_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';

/// [IRiverDataSource] for GEOGLOWS (global, non-US rivers). A thin adapter over
/// the existing [IGeoglowsApiService] proxy client.
///
/// **GEOGLOWS stamps its run 00Z but PUBLISHES at 10:15-10:30 UTC**, and this
/// file used to conflate the two: the window ran to the next midnight, so a
/// device that fetched at 00:20 held the previous day's run for a further
/// 24 hours while a newer one had existed since 10:15. Nothing surfaced it
/// until Phase 7 gave the app a run-age check, which then warned — correctly —
/// for about six hours a day on the live path.
///
/// The measurement is not new. `functions_geoglows/main.py` records the daily
/// run publishing at 10:15-10:30 UTC from S3 Last-Modified on two consecutive
/// days, and the flood builder is scheduled at 11:00 because of it. This file
/// simply never used it.
class GeoglowsDataSource implements IRiverDataSource {
  GeoglowsDataSource({
    required IGeoglowsApiService api,
    required IFlowUnitPreferenceService unitService,
  }) : _api = api,
       _unitService = unitService;

  final IGeoglowsApiService _api;
  final IFlowUnitPreferenceService _unitService;

  /// Slack past publication: the proxy has a cold start and the run isn't
  /// instant.
  static const Duration _skew = Duration(minutes: 15);

  /// The hour/minute GEOGLOWS has finished publishing by, measured.
  static const int _publishHourUtc = 10;
  static const int _publishMinuteUtc = 30;

  /// How soon to look again when publication is LATE.
  ///
  /// Without this a device that fetched just after the expected time would
  /// hold yesterday's run until the next day's window — the original bug in a
  /// new place, one publication later.
  static const Duration _lateRetry = Duration(minutes: 30);

  /// When a fetched GEOGLOWS value stops being the newest that exists.
  ///
  /// Pure and static so the schedule can be tested without an API, a clock or
  /// a widget.
  ///
  /// [run] is the run identity actually received, or null when the response
  /// carried none.
  static DateTime windowFor(DateTime now, DateTime? run) {
    final utc = now.toUtc();
    final todayPublish = DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
      _publishHourUtc,
      _publishMinuteUtc,
    ).add(_skew);
    final tomorrowPublish = todayPublish.add(const Duration(days: 1));

    // No run identity: fall back to the publication schedule, which is still
    // far better than midnight.
    if (run == null) {
      return utc.isBefore(todayPublish) ? todayPublish : tomorrowPublish;
    }

    // We hold today's run — good until the next one publishes.
    final todayStamp = DateTime.utc(utc.year, utc.month, utc.day);
    if (!run.toUtc().isBefore(todayStamp)) return tomorrowPublish;

    // We do NOT hold today's run. Before the expected time that is normal, so
    // wait for it; after it, publication is late and we look again shortly
    // rather than sitting on yesterday's water for a day.
    return utc.isBefore(todayPublish) ? todayPublish : utc.add(_lateRetry);
  }

  @override
  ForecastSource get source => ForecastSource.geoglows;

  @override
  Set<ForecastProduct> get supportedProducts => const {
    ForecastProduct.geoglowsForecast,
  };

  @override
  DateTime validUntil(
    ForecastProduct product,
    DateTime now, {
    // Accepted and ignored. GEOGLOWS runs ONE global model on one daily
    // schedule, so unlike NWM its window does not vary by reach. Named and
    // explained rather than silently dropped, so the next reader does not have
    // to check whether it was an oversight.
    required String reachId,
  }) {
    switch (product) {
      case ForecastProduct.geoglowsForecast:
      case ForecastProduct.geoglowsEnsemble:
        // Schedule-only form, used when a fetch supplies no window of its own.
        return windowFor(now, null);
      default:
        throw ArgumentError('GEOGLOWS does not support $product');
    }
  }

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    switch (key.product) {
      case ForecastProduct.geoglowsForecast:
        final forecast = await _api.fetchForecast(key.reachId);
        return SourceFetchResult(
          payload: GeoglowsForecastPayload.encode(forecast),
          // The API converted to the current unit; tag with the canonical token
          // (CFS/CMS) so read-time conversion knows what it holds.
          unit: _unitService.currentFlowUnit,
          // GEOGLOWS publishes one run per UTC day; the generation stamp is
          // its identity (ADR 0011 Phase 2, run recorded on the entry) —
          // unless the response carried none and the stamp is wall-clock, in
          // which case null: a fabricated run makes every refetch look like
          // an update. Round 6 caught the unconditional version doing exactly
          // what the NWM side's own comment forbids, one source over.
          runId: forecast.generatedAtIsFallback
              ? null
              : forecast.generatedAt.toIso8601String(),
          // Computed from the run we actually received, not from the clock
          // alone: holding yesterday's forecast until tomorrow's midnight is
          // what made the live path warn truthfully for six hours a day.
          validUntil: windowFor(
            DateTime.now().toUtc(),
            forecast.generatedAtIsFallback ? null : forecast.generatedAt,
          ),
        );
      default:
        throw ArgumentError('GEOGLOWS does not support ${key.product}');
    }
  }
}
