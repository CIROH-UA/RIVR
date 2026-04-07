// test/services/2_coordinators/features/forecast/forecast_repository_impl_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/hourly_flow_data.dart';
import 'package:rivr/models/1_domain/shared/forecast_chart_data.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/2_coordinators/features/forecast/forecast_repository_impl.dart';

/// Stub that returns canned responses or throws on demand.
class _StubForecastService implements IForecastService {
  ForecastResponse? responseToReturn;
  ReachDetailsData? detailsToReturn;
  Exception? exceptionToThrow;

  @override
  Future<ForecastResponse> loadOverviewData(String reachId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return responseToReturn!;
  }

  @override
  Future<ForecastResponse> loadSupplementaryData(
    String reachId,
    ForecastResponse existingData,
  ) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return responseToReturn!;
  }

  @override
  Future<ForecastResponse> loadCompleteReachData(String reachId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return responseToReturn!;
  }

  @override
  Future<ForecastResponse> loadSpecificForecast(
    String reachId,
    String forecastType,
  ) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return responseToReturn!;
  }

  @override
  Future<ForecastResponse> refreshReachData(String reachId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return responseToReturn!;
  }

  @override
  Future<ReachDetailsData> loadReachDetailsData(String reachId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return detailsToReturn!;
  }

  // ── Unused methods (required by interface) ──────────────────────────────

  @override
  Future<bool> isReachCached(String reachId) async => false;
  @override
  Future<Map<String, dynamic>> getCacheStats() async => {};
  @override
  Future<ForecastResponse> loadCurrentFlowOnly(String reachId) async =>
      throw UnimplementedError();
  @override
  Future<ReachData> loadBasicReachInfo(String reachId) async =>
      throw UnimplementedError();
  @override
  ForecastResponse mergeCurrentFlowData(
    ForecastResponse existing,
    ForecastResponse newFlowData,
  ) =>
      throw UnimplementedError();
  @override
  double? getCurrentFlow(ForecastResponse forecast, {String? preferredType}) =>
      null;
  @override
  String getFlowCategory(ForecastResponse forecast, {String? preferredType}) =>
      'Unknown';
  @override
  List<String> getAvailableForecastTypes(ForecastResponse forecast) => [];
  @override
  bool hasEnsembleData(ForecastResponse forecast) => false;
  @override
  Map<String, dynamic> getEnsembleSummary(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      {};
  @override
  List<HourlyFlowDataPoint> getShortRangeHourlyData(
    ForecastResponse forecast,
  ) =>
      [];
  @override
  List<HourlyFlowDataPoint> getAllShortRangeHourlyData(
    ForecastResponse forecast,
  ) =>
      [];
  @override
  List<EnsembleStatPoint> getEnsembleStatistics(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      [];
  @override
  bool hasMultipleEnsembleMembers(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      false;
  @override
  Map<String, List<ChartData>> getEnsembleSeriesForChart(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      {};
  @override
  List<ChartDataPoint> getEnsembleReferenceData(
    ForecastResponse forecast,
    String forecastType,
  ) =>
      [];
  @override
  void clearUnitDependentCaches() {}
  @override
  void clearComputedCaches() {}
}

ForecastResponse _createForecast({String reachId = '12345'}) {
  return ForecastResponse(
    reach: ReachData(
      reachId: reachId,
      riverName: 'Test River',
      latitude: 35.0,
      longitude: -90.0,
      availableForecasts: ['short_range'],
      cachedAt: DateTime(2026, 4, 6),
    ),
    mediumRange: {},
    longRange: {},
  );
}

ReachDetailsData _createDetails() {
  return const ReachDetailsData(
    riverName: 'Test River',
    formattedLocation: 'City, ST',
    currentFlow: 150.0,
    flowCategory: 'Normal',
    latitude: 35.0,
    longitude: -90.0,
    isClassificationAvailable: true,
  );
}

void main() {
  late _StubForecastService stubService;
  late ForecastRepositoryImpl repository;

  setUp(() {
    stubService = _StubForecastService();
    repository = ForecastRepositoryImpl(forecastService: stubService);
  });

  group('ForecastRepositoryImpl — loadOverview', () {
    test('returns success with forecast data', () async {
      stubService.responseToReturn = _createForecast();

      final result = await repository.loadOverview('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data.reach.reachId, '12345');
      expect(result.data.reach.riverName, 'Test River');
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('NOAA API unavailable');

      final result = await repository.loadOverview('12345');
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('ForecastRepositoryImpl — loadSupplementary', () {
    test('returns success with enhanced data', () async {
      final existing = _createForecast();
      stubService.responseToReturn = _createForecast();

      final result = await repository.loadSupplementary('12345', existing);
      expect(result.isSuccess, isTrue);
      expect(result.data.reach.reachId, '12345');
    });

    test('returns failure when service throws', () async {
      final existing = _createForecast();
      stubService.exceptionToThrow = Exception('Return periods unavailable');

      final result = await repository.loadSupplementary('12345', existing);
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('ForecastRepositoryImpl — loadComplete', () {
    test('returns success with complete forecast', () async {
      stubService.responseToReturn = _createForecast();

      final result = await repository.loadComplete('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data.reach.reachId, '12345');
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('Network timeout');

      final result = await repository.loadComplete('12345');
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('ForecastRepositoryImpl — loadSpecificForecast', () {
    test('returns success with specific forecast type', () async {
      stubService.responseToReturn = _createForecast();

      final result = await repository.loadSpecificForecast(
        '12345',
        'short_range',
      );
      expect(result.isSuccess, isTrue);
      expect(result.data.reach.reachId, '12345');
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('Forecast type not available');

      final result = await repository.loadSpecificForecast(
        '12345',
        'medium_range',
      );
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('ForecastRepositoryImpl — refresh', () {
    test('returns success with refreshed data', () async {
      stubService.responseToReturn = _createForecast();

      final result = await repository.refresh('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data.reach.reachId, '12345');
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('Cache refresh failed');

      final result = await repository.refresh('12345');
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('ForecastRepositoryImpl — getReachDetails', () {
    test('returns success with reach details', () async {
      stubService.detailsToReturn = _createDetails();

      final result = await repository.getReachDetails('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data.riverName, 'Test River');
      expect(result.data.currentFlow, 150.0);
      expect(result.data.flowCategory, 'Normal');
      expect(result.data.isClassificationAvailable, isTrue);
    });

    test('returns failure when service throws', () async {
      stubService.exceptionToThrow = Exception('Reach not found');

      final result = await repository.getReachDetails('99999');
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('ForecastRepositoryImpl — ServiceResult properties', () {
    test('failure result has ServiceException with context', () async {
      stubService.exceptionToThrow = Exception('Some error');

      final result = await repository.loadOverview('12345');
      expect(result.isFailure, isTrue);
      expect(result.exception, isNotNull);
      expect(result.exception!.technicalDetail, isNotNull);
    });

    test('success result has no exception', () async {
      stubService.responseToReturn = _createForecast();

      final result = await repository.loadOverview('12345');
      expect(result.isSuccess, isTrue);
      expect(result.exception, isNull);
    });
  });
}
