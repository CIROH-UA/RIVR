// test/services/2_coordinators/features/favorites/favorites_repository_impl_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/hourly_flow_data.dart';
import 'package:rivr/models/1_domain/shared/forecast_chart_data.dart';
import 'package:rivr/services/1_contracts/shared/i_favorites_service.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_noaa_api_service.dart';
import 'package:rivr/services/2_coordinators/features/favorites/favorites_repository_impl.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────

class _StubFavoritesService implements IFavoritesService {
  List<FavoriteRiver>? favoritesToReturn;
  bool successToReturn = true;
  Exception? exceptionToThrow;

  @override
  Future<List<FavoriteRiver>> loadFavorites() async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return favoritesToReturn ?? [];
  }

  @override
  Future<bool> addFavorite(String reachId, {String? customName, double? latitude, double? longitude}) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return successToReturn;
  }

  @override
  Future<bool> removeFavorite(String reachId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return successToReturn;
  }

  @override
  Future<bool> updateFavorite(
    String reachId, {
    String? customName,
    String? riverName,
    String? customImageAsset,
    double? lastKnownFlow,
    DateTime? lastUpdated,
    double? latitude,
    double? longitude,
  }) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return successToReturn;
  }

  @override
  Future<bool> reorderFavorites(List<FavoriteRiver> reorderedFavorites) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return successToReturn;
  }

  // ── Unused methods ──
  @override
  Future<bool> saveFavorites(List<FavoriteRiver> favorites) async => true;
  @override
  Future<bool> isFavorite(String reachId) async => false;
  @override
  Future<int> getFavoritesCount() async => 0;
  @override
  Future<bool> clearAllFavorites() async => true;
}

class _StubForecastService implements IForecastService {
  ForecastResponse? responseToReturn;
  ReachDetailsData? detailsToReturn;
  Exception? exceptionToThrow;

  @override
  Future<ForecastResponse> loadCurrentFlowOnly(String reachId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return responseToReturn!;
  }

  @override
  Future<ForecastResponse> refreshReachData(String reachId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return responseToReturn!;
  }

  // ── Unused methods ──
  @override
  Future<ForecastResponse> loadOverviewData(String reachId) async => throw UnimplementedError();
  @override
  Future<ForecastResponse> loadSupplementaryData(String reachId, ForecastResponse existingData) async => throw UnimplementedError();
  @override
  Future<ForecastResponse> loadCompleteReachData(String reachId) async => throw UnimplementedError();
  @override
  Future<ForecastResponse> loadSpecificForecast(String reachId, String forecastType) async => throw UnimplementedError();
  @override
  Future<bool> isReachCached(String reachId) async => false;
  @override
  Future<Map<String, dynamic>> getCacheStats() async => {};
  @override
  Future<ReachData> loadBasicReachInfo(String reachId) async => throw UnimplementedError();
  @override
  ForecastResponse mergeCurrentFlowData(ForecastResponse existing, ForecastResponse newFlowData) => throw UnimplementedError();
  @override
  double? getCurrentFlow(ForecastResponse forecast, {String? preferredType}) => null;
  @override
  String getFlowCategory(ForecastResponse forecast, {String? preferredType}) => 'Unknown';
  @override
  List<String> getAvailableForecastTypes(ForecastResponse forecast) => [];
  @override
  bool hasEnsembleData(ForecastResponse forecast) => false;
  @override
  Map<String, dynamic> getEnsembleSummary(ForecastResponse forecast, String forecastType) => {};
  @override
  List<HourlyFlowDataPoint> getShortRangeHourlyData(ForecastResponse forecast) => [];
  @override
  List<HourlyFlowDataPoint> getAllShortRangeHourlyData(ForecastResponse forecast) => [];
  @override
  List<EnsembleStatPoint> getEnsembleStatistics(ForecastResponse forecast, String forecastType) => [];
  @override
  bool hasMultipleEnsembleMembers(ForecastResponse forecast, String forecastType) => false;
  @override
  Map<String, List<ChartData>> getEnsembleSeriesForChart(ForecastResponse forecast, String forecastType) => {};
  @override
  List<ChartDataPoint> getEnsembleReferenceData(ForecastResponse forecast, String forecastType) => [];
  @override
  void clearUnitDependentCaches() {}
  @override
  void clearComputedCaches() {}
  @override
  Future<ReachDetailsData> loadReachDetailsData(String reachId) async => throw UnimplementedError();
}

class _StubReachCacheService implements IReachCacheService {
  ReachData? cachedReach;

  @override
  Future<ReachData?> get(String reachId) async => cachedReach;
  @override
  Future<CacheResult<ReachData>?> getWithFreshness(String reachId) async => null;
  @override
  Future<void> store(ReachData reach) async {}
  @override
  Future<void> clearReach(String reachId) async {}
  @override
  Future<void> clear() async {}
  @override
  Future<bool> isCached(String reachId) async => false;
  @override
  Future<Map<String, dynamic>> getCacheStats() async => {};
  @override
  Map<String, dynamic> getCacheEffectiveness() => {};
  @override
  Future<void> forceRefresh(String reachId) async {}
  @override
  Future<int> cleanupStaleEntries() async => 0;
  @override
  Future<void> initialize() async {}
  @override
  bool get isReady => true;
}

class _StubFlowUnitPreferenceService implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  bool get isCFS => true;
  @override
  bool get isCMS => false;
  @override
  void setFlowUnit(String unit) {}
  @override
  String normalizeUnit(String unit) => unit;
  @override
  double convertFlow(double value, String fromUnit, String toUnit) => value;
  @override
  double convertToPreferredUnit(double value, String fromUnit) => value;
  @override
  double convertFromPreferredUnit(double value, String toUnit) => value;
  @override
  String getDisplayUnit() => 'CFS';
  @override
  void resetToDefault() {}
}

class _StubNoaaApiService implements INoaaApiService {
  List<dynamic> returnPeriodsToReturn = [];
  Exception? exceptionToThrow;

  @override
  Future<List<dynamic>> fetchReturnPeriods(String reachId) async {
    if (exceptionToThrow != null) throw exceptionToThrow!;
    return returnPeriodsToReturn;
  }

  // ── Unused methods ──
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

// ── Helpers ────────────────────────────────────────────────────────────────

FavoriteRiver _createFavorite({
  String reachId = '12345',
  String riverName = 'Test River',
}) {
  return FavoriteRiver(
    reachId: reachId,
    riverName: riverName,
    displayOrder: 0,
    lastKnownFlow: 150.0,
    storedFlowUnit: 'CFS',
    lastUpdated: DateTime(2026, 4, 6),
    latitude: 35.0,
    longitude: -90.0,
  );
}

ForecastResponse _createForecast({
  String reachId = '12345',
  bool hasReturnPeriods = false,
}) {
  return ForecastResponse(
    reach: ReachData(
      reachId: reachId,
      riverName: 'Test River',
      latitude: 35.0,
      longitude: -90.0,
      availableForecasts: ['short_range'],
      cachedAt: DateTime(2026, 4, 6),
      returnPeriods: hasReturnPeriods ? {2: 100.0, 5: 200.0} : null,
    ),
    mediumRange: {},
    longRange: {},
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  late _StubFavoritesService stubFavoritesService;
  late _StubForecastService stubForecastService;
  late _StubReachCacheService stubCacheService;
  late _StubFlowUnitPreferenceService stubUnitService;
  late _StubNoaaApiService stubApiService;
  late FavoritesRepositoryImpl repository;

  setUp(() {
    stubFavoritesService = _StubFavoritesService();
    stubForecastService = _StubForecastService();
    stubCacheService = _StubReachCacheService();
    stubUnitService = _StubFlowUnitPreferenceService();
    stubApiService = _StubNoaaApiService();
    repository = FavoritesRepositoryImpl(
      favoritesService: stubFavoritesService,
      forecastService: stubForecastService,
      cacheService: stubCacheService,
      unitService: stubUnitService,
      apiService: stubApiService,
    );
  });

  group('FavoritesRepositoryImpl — loadFavorites', () {
    test('returns success with favorites list', () async {
      stubFavoritesService.favoritesToReturn = [
        _createFavorite(),
        _createFavorite(reachId: '67890', riverName: 'Other River'),
      ];

      final result = await repository.loadFavorites();
      expect(result.isSuccess, isTrue);
      expect(result.data.length, 2);
      expect(result.data[0].reachId, '12345');
    });

    test('returns success with empty list', () async {
      stubFavoritesService.favoritesToReturn = [];

      final result = await repository.loadFavorites();
      expect(result.isSuccess, isTrue);
      expect(result.data, isEmpty);
    });

    test('returns failure when service throws', () async {
      stubFavoritesService.exceptionToThrow = Exception('Firestore unavailable');

      final result = await repository.loadFavorites();
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('FavoritesRepositoryImpl — addFavorite', () {
    test('returns success with true when added', () async {
      stubFavoritesService.successToReturn = true;

      final result = await repository.addFavorite('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data, isTrue);
    });

    test('returns success with false when add failed', () async {
      stubFavoritesService.successToReturn = false;

      final result = await repository.addFavorite('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data, isFalse);
    });

    test('returns failure when service throws', () async {
      stubFavoritesService.exceptionToThrow = Exception('Permission denied');

      final result = await repository.addFavorite('12345');
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('FavoritesRepositoryImpl — removeFavorite', () {
    test('returns success with true when removed', () async {
      stubFavoritesService.successToReturn = true;

      final result = await repository.removeFavorite('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data, isTrue);
    });

    test('returns failure when service throws', () async {
      stubFavoritesService.exceptionToThrow = Exception('Network error');

      final result = await repository.removeFavorite('12345');
      expect(result.isFailure, isTrue);
    });
  });

  group('FavoritesRepositoryImpl — updateFavorite', () {
    test('returns success when updated', () async {
      stubFavoritesService.successToReturn = true;

      final result = await repository.updateFavorite(
        '12345',
        customName: 'My River',
      );
      expect(result.isSuccess, isTrue);
      expect(result.data, isTrue);
    });

    test('returns failure when service throws', () async {
      stubFavoritesService.exceptionToThrow = Exception('Update failed');

      final result = await repository.updateFavorite('12345');
      expect(result.isFailure, isTrue);
    });
  });

  group('FavoritesRepositoryImpl — reorderFavorites', () {
    test('returns success when reordered', () async {
      stubFavoritesService.successToReturn = true;

      final result = await repository.reorderFavorites([_createFavorite()]);
      expect(result.isSuccess, isTrue);
      expect(result.data, isTrue);
    });

    test('returns failure when service throws', () async {
      stubFavoritesService.exceptionToThrow = Exception('Reorder failed');

      final result = await repository.reorderFavorites([]);
      expect(result.isFailure, isTrue);
    });
  });

  group('FavoritesRepositoryImpl — getFlowData', () {
    test('returns success with forecast including return periods', () async {
      stubForecastService.responseToReturn =
          _createForecast(hasReturnPeriods: true);

      final result = await repository.getFlowData('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data.reach.hasReturnPeriods, isTrue);
    });

    test('returns success with forecast without return periods', () async {
      stubForecastService.responseToReturn = _createForecast();

      final result = await repository.getFlowData('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data.reach.reachId, '12345');
    });

    test('returns failure when forecast service throws', () async {
      stubForecastService.exceptionToThrow =
          Exception('Forecast service error');

      final result = await repository.getFlowData('12345');
      expect(result.isFailure, isTrue);
      expect(result.errorMessage, isNotEmpty);
    });
  });

  group('FavoritesRepositoryImpl — refreshFlowData', () {
    test('returns success with refreshed forecast', () async {
      stubForecastService.responseToReturn = _createForecast();

      final result = await repository.refreshFlowData('12345');
      expect(result.isSuccess, isTrue);
      expect(result.data.reach.reachId, '12345');
    });

    test('returns failure when service throws', () async {
      stubForecastService.exceptionToThrow =
          Exception('Refresh failed');

      final result = await repository.refreshFlowData('12345');
      expect(result.isFailure, isTrue);
    });
  });

  group('FavoritesRepositoryImpl — ServiceResult properties', () {
    test('failure result has ServiceException with context', () async {
      stubFavoritesService.exceptionToThrow = Exception('Some error');

      final result = await repository.loadFavorites();
      expect(result.isFailure, isTrue);
      expect(result.exception, isNotNull);
      expect(result.exception!.technicalDetail, isNotNull);
    });

    test('success result has no exception', () async {
      stubFavoritesService.favoritesToReturn = [_createFavorite()];

      final result = await repository.loadFavorites();
      expect(result.isSuccess, isTrue);
      expect(result.exception, isNull);
    });
  });
}
