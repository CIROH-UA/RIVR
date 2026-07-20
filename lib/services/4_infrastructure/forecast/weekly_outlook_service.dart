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
import 'package:rivr/services/4_infrastructure/geo/geocoding_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/utils/forecast_peak.dart';
import 'package:rivr/utils/forecast_trend.dart';

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
  })  : _forecastService = forecastService,
        _riverData = riverData,
        _unitService = unitService;

  /// Load + summarize every favorite in parallel; failed reaches are skipped so
  /// one bad fetch doesn't blank the whole page. Result is newsworthiness-ranked.
  Future<List<OutlookRow>> buildOutlook(List<FavoriteRiver> favorites) async {
    final rows = await Future.wait(
      favorites.map(_buildRow),
    );
    final result = rows.whereType<OutlookRow>().toList()
      ..sort(OutlookRow.byNewsworthiness);
    return result;
  }

  Future<OutlookRow?> _buildRow(FavoriteRiver favorite) async {
    try {
      return favorite.source.isGeoglows
          ? await _buildGeoglowsRow(favorite)
          : await _buildNwmRow(favorite);
    } catch (e) {
      AppLogger.warning(
        'WeeklyOutlookService',
        'Skipping ${favorite.reachId} (${favorite.source.id}) in outlook: $e',
      );
      return null;
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
      location: await _locationLabel(lat, lon),
      unit: unitLabel,
      sparkline: flows,
      trend: computeFlowTrend(flows),
      peakFlow: peak?.flow,
      peakTime: peak?.time.toLocal(),
      category: category,
      categoryIndex: categoryIndex,
    );
  }

  /// Reverse-geocode to a place label — "City, ST" in the US, "City, Country"
  /// elsewhere. Best-effort: null when coords/geocoding are unavailable so a
  /// slow or failed lookup never blocks the row.
  Future<String?> _locationLabel(double? lat, double? lon) async {
    if (lat == null || lon == null || (lat == 0 && lon == 0)) return null;
    try {
      final geo = await GeocodingService.reverseGeocode(lat, lon);
      final city = geo['city'];
      final state = geo['state'];
      final country = geo['country'];
      if (city == null || city.isEmpty) {
        return (country != null && country.isNotEmpty) ? country : null;
      }
      final isUS = country == 'United States' ||
          country == 'United States of America';
      if (isUS && state != null && state.isNotEmpty) return '$city, $state';
      if (country != null && country.isNotEmpty) return '$city, $country';
      return city;
    } catch (e) {
      AppLogger.debug('WeeklyOutlookService', 'Geocode failed: $e');
      return null;
    }
  }
}
