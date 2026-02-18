import 'package:rivr/core/models/reach_data.dart';

/// Factory methods for creating test data.

ReachData createTestReachData({
  String reachId = '23021904',
  String riverName = 'Deep Creek',
  double latitude = 47.6588,
  double longitude = -117.4260,
  String? city = 'Spokane',
  String? state = 'WA',
  List<String> availableForecasts = const [
    'analysis_assimilation',
    'short_range',
    'medium_range',
    'long_range',
  ],
  Map<int, double>? returnPeriods,
  List<String>? upstreamReaches,
  List<String>? downstreamReaches,
  String? customName,
  DateTime? cachedAt,
  bool isPartiallyLoaded = false,
}) {
  return ReachData(
    reachId: reachId,
    riverName: riverName,
    latitude: latitude,
    longitude: longitude,
    city: city,
    state: state,
    availableForecasts: availableForecasts,
    returnPeriods: returnPeriods,
    upstreamReaches: upstreamReaches,
    downstreamReaches: downstreamReaches,
    customName: customName,
    cachedAt: cachedAt ?? DateTime(2025, 1, 1),
    isPartiallyLoaded: isPartiallyLoaded,
  );
}

/// Creates a ReachData with return period thresholds for flow category testing.
ReachData createTestReachDataWithReturnPeriods({
  String reachId = '23021904',
  double threshold2yr = 100.0,
  double threshold5yr = 200.0,
  double threshold10yr = 300.0,
  double threshold25yr = 400.0,
}) {
  return createTestReachData(
    reachId: reachId,
    returnPeriods: {
      2: threshold2yr,
      5: threshold5yr,
      10: threshold10yr,
      25: threshold25yr,
    },
  );
}

/// Creates a minimal NOAA API response map for testing ReachData.fromNoaaApi.
Map<String, dynamic> createTestNoaaApiResponse({
  String reachId = '23021904',
  String name = 'Deep Creek',
  double latitude = 47.6588,
  double longitude = -117.4260,
  List<String> streamflow = const ['short_range', 'medium_range'],
  Map<String, dynamic>? route,
}) {
  return {
    'reachId': reachId,
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    'streamflow': streamflow,
    if (route != null) 'route': route,
  };
}

/// Creates a return period API response array for testing ReachData.fromReturnPeriodApi.
List<dynamic> createTestReturnPeriodApiResponse({
  String featureId = '23021904',
  double returnPeriod2 = 3518.03,
  double returnPeriod5 = 6119.41,
  double returnPeriod10 = 7841.75,
  double returnPeriod25 = 10200.50,
}) {
  return [
    {
      'feature_id': featureId,
      'return_period_2': returnPeriod2,
      'return_period_5': returnPeriod5,
      'return_period_10': returnPeriod10,
      'return_period_25': returnPeriod25,
    },
  ];
}

ForecastPoint createTestForecastPoint({
  DateTime? validTime,
  double flow = 150.0,
}) {
  return ForecastPoint(
    validTime: validTime ?? DateTime(2025, 6, 15, 12, 0),
    flow: flow,
  );
}

ForecastSeries createTestForecastSeries({
  DateTime? referenceTime,
  String units = 'CMS',
  List<ForecastPoint>? data,
}) {
  return ForecastSeries(
    referenceTime: referenceTime,
    units: units,
    data: data ??
        [
          createTestForecastPoint(
            validTime: DateTime(2025, 6, 15, 10, 0),
            flow: 100.0,
          ),
          createTestForecastPoint(
            validTime: DateTime(2025, 6, 15, 11, 0),
            flow: 120.0,
          ),
          createTestForecastPoint(
            validTime: DateTime(2025, 6, 15, 12, 0),
            flow: 150.0,
          ),
        ],
  );
}
