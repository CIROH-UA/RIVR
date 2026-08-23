// lib/services/4_infrastructure/forecast/weekly_outlook_service.dart

import 'package:rivr/models/1_domain/features/forecast/weekly_outlook_row.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/geoglows_forecast_payload.dart';
import 'package:rivr/services/1_contracts/shared/i_geocoding_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/utils/forecast_peak.dart';
import 'package:rivr/utils/forecast_trend.dart';

/// The outcome of building a week's outlook: the rows that came back, and the
/// favourites that could not be loaded at all.
///
/// Failures used to be swallowed to a bare `null` and dropped, so a total
/// upstream outage — every favourite throwing — was indistinguishable from
/// "your rivers have no forecast this week". The page showed a dead-end card
/// with no Retry. Review round 11 reproduced that with both datasources
/// throwing. Naming the failures is what lets the page tell the two apart and
/// offer a way out.
class OutlookResult {
  const OutlookResult({required this.rows, required this.failedNames});

  final List<OutlookRow> rows;

  /// Display names of the favourites whose load threw, in favourites order.
  final List<String> failedNames;

  /// Nothing loaded and something failed — an outage, not an empty week.
  bool get isTotalFailure => rows.isEmpty && failedNames.isNotEmpty;
}

/// Builds the week-ahead [OutlookRow]s for the Weekly Outlook page from a user's
/// favorites — fetching each reach's forecast series (NWM medium-range or
/// GEOGLOWS 15-day), then deriving trend, peak, and flood category. Rows are
/// returned ranked most-newsworthy first.
class WeeklyOutlookService {
  final IForecastService _forecastService;
  final IRiverDataRepository _riverData;
  final IFlowUnitPreferenceService _unitService;

  WeeklyOutlookService({
    required IForecastService forecastService,
    required IRiverDataRepository riverData,
    required IFlowUnitPreferenceService unitService,
    required IGeocodingService geocoder,
  })  : _forecastService = forecastService,
        _riverData = riverData,
        _unitService = unitService,
        _geocoder = geocoder;

  final IGeocodingService _geocoder;

  /// Load + summarize every favorite **in parallel**; a reach that fails is
  /// reported rather than dropped, so one bad fetch doesn't blank the page and a
  /// total outage is still distinguishable. Rows are newsworthiness-ranked.
  ///
  /// The parallelism is the whole point of this method: N favourites each cost a
  /// `loadCompleteReachData`, and running them in sequence is the 3-5 minute
  /// stall ADR 0010 was opened for. Guarded in weekly_outlook_service_test.
  Future<OutlookResult> buildOutlook(List<FavoriteRiver> favorites) async {
    final outcomes = await Future.wait(favorites.map(_buildRow));
    final rows = [
      for (final o in outcomes)
        if (o.row != null) o.row!,
    ]..sort(OutlookRow.byNewsworthiness);
    return OutlookResult(
      rows: rows,
      failedNames: [
        for (final o in outcomes)
          if (o.failedName != null) o.failedName!,
      ],
    );
  }

  /// A row, or the name of the favourite that failed. Both null means the reach
  /// loaded fine but has no forecast points — an empty week, not a failure.
  Future<({OutlookRow? row, String? failedName})> _buildRow(
    FavoriteRiver favorite,
  ) async {
    try {
      final row = favorite.source.isGeoglows
          ? await _buildGeoglowsRow(favorite)
          : await _buildNwmRow(favorite);
      return (row: row, failedName: null);
    } catch (e) {
      AppLogger.warning(
        'WeeklyOutlookService',
        'Skipping ${favorite.reachId} (${favorite.source.id}) in outlook: $e',
      );
      return (row: null, failedName: favorite.displayName);
    }
  }

  Future<OutlookRow?> _buildNwmRow(FavoriteRiver favorite) async {
    final forecast = await _forecastService.loadCompleteReachData(
      favorite.reachId,
    );

    // Medium-range ensemble mean covers ~10 days — the "week ahead".
    final series = forecast.mediumRange['mean']?.data ?? const [];
    final points = [
      for (final p in series) (flow: p.flow, time: p.validTime),
    ];
    if (points.isEmpty) return null;

    // Return periods are native CMS; convert to the user's unit to match the
    // (already-converted) forecast flows before classifying.
    final unit = _unitService.currentFlowUnit;
    final thresholds = forecast.reach.returnPeriods?.map(
      (year, flow) => MapEntry(year, _unitService.convertFlow(flow, 'CMS', unit)),
    );

    return _assemble(
      favorite: favorite,
      points: points,
      thresholds: thresholds,
      unitLabel: _unitService.getDisplayUnit(),
      displayName: forecast.reach.riverName.isNotEmpty
          ? forecast.reach.riverName
          : favorite.displayName,
      // Prefer the favorite's stored coords; fall back to the reach's.
      lat: favorite.latitude ?? forecast.reach.latitude,
      lon: favorite.longitude ?? forecast.reach.longitude,
    );
  }

  Future<OutlookRow?> _buildGeoglowsRow(FavoriteRiver favorite) async {
    final entry = await _riverData.read(
      RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: favorite.reachId,
        product: ForecastProduct.geoglowsForecast,
      ),
    );
    if (entry == null) return null;

    final fc = GeoglowsForecastPayload.decode(entry, _unitService);
    final points = [
      for (final p in fc.points) (flow: p.median, time: p.validTime),
    ];
    if (points.isEmpty) return null;

    // GEOGLOWS flows + return periods are already in the user's unit.
    return _assemble(
      favorite: favorite,
      points: points,
      thresholds: fc.returnPeriods,
      unitLabel: fc.unit,
      displayName: favorite.displayName,
      lat: favorite.latitude,
      lon: favorite.longitude,
    );
  }

  /// Shared row assembly: window to what's ahead, then derive sparkline, trend,
  /// peak, category, and a reverse-geocoded place label.
  Future<OutlookRow> _assemble({
    required FavoriteRiver favorite,
    required List<({double flow, DateTime time})> points,
    required Map<int, double>? thresholds,
    required String unitLabel,
    required String displayName,
    required double? lat,
    required double? lon,
  }) async {
    final upcoming = ForecastPeak.upcomingPoints(points);
    final window = upcoming.isNotEmpty ? upcoming : points;
    final flows = [for (final p in window) p.flow];

    final peak = ForecastPeak.upcoming(points);
    final categoryIndex = FlowClassification.indexFor(peak?.flow, thresholds);
    final category = FlowClassification.category(peak?.flow, thresholds);

    return OutlookRow(
      reachId: favorite.reachId,
      source: favorite.source,
      displayName: displayName,
      // No await: the place label is decoration, and awaiting it here made
      // every row wait on a Mapbox hop — with buildOutlook waiting on all rows,
      // that gated the entire page on geocoding. Same shape already fixed on
      // the map sheet and both forecast-page branches; missed here until
      // review. Rows carry a null label and the page fills it afterwards.
      location: null,
      unit: unitLabel,
      sparkline: flows,
      latitude: lat,
      longitude: lon,
      trend: computeFlowTrend(flows),
      peakFlow: peak?.flow,
      peakTime: peak?.time.toLocal(),
      category: category,
      categoryIndex: categoryIndex,
    );
  }

  /// Reverse-geocode a row's coordinate, for the consumer to call AFTER the
  /// page has rendered. Best-effort (null on failure).
  Future<String?> placeLabelFor(double? lat, double? lon) =>
      _geocoder.placeLabel(lat, lon);
}
