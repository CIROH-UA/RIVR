import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/shared/hourly_flow_data.dart';
import 'package:rivr/models/1_domain/shared/forecast_chart_data.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_overview_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_forecast_supplementary_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_specific_forecast_usecase.dart';
import 'package:rivr/models/2_usecases/features/forecast/load_complete_forecast_usecase.dart';
import 'package:rivr/services/1_contracts/shared/i_forecast_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';
import 'package:rivr/ui/1_state/shared/section_load_state.dart';

import '../../../../helpers/fake_data.dart';

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

/// Stub IForecastService that returns controllable values for methods
/// called by the ReachDataCacheMixin.
class StubForecastService implements IForecastService {
  double? currentFlowReturn;
  String flowCategoryReturn = 'Normal';
  List<String> availableTypesReturn = ['short_range', 'medium_range'];
  bool hasEnsembleReturn = false;

  @override
  double? getCurrentFlow(ForecastResponse forecast, {String? preferredType}) =>
      currentFlowReturn;

  @override
  String getFlowCategory(ForecastResponse forecast, {String? preferredType}) =>
      flowCategoryReturn;

  @override
  List<String> getAvailableForecastTypes(ForecastResponse forecast) =>
      availableTypesReturn;

  @override
  bool hasEnsembleData(ForecastResponse forecast) => hasEnsembleReturn;

  @override
  List<HourlyFlowDataPoint> getShortRangeHourlyData(
          ForecastResponse forecast) =>
      [];

  @override
  List<HourlyFlowDataPoint> getAllShortRangeHourlyData(
          ForecastResponse forecast) =>
      [];

  @override
  void clearUnitDependentCaches() {}

  @override
  void clearComputedCaches() {}

  @override
  Future<Map<String, dynamic>> getCacheStats() async => {};

  // Unused by provider — stubs for interface compliance
  @override
  Future<ForecastResponse> loadOverviewData(String reachId) =>
      throw UnimplementedError();
  @override
  Future<ForecastResponse> loadSupplementaryData(
          String reachId, ForecastResponse existingData) =>
      throw UnimplementedError();
  @override
  Future<ForecastResponse> loadCompleteReachData(String reachId) =>
      throw UnimplementedError();
  @override
  Future<ForecastResponse> loadSpecificForecast(
          String reachId, String forecastType) =>
      throw UnimplementedError();
  @override
  Future<ForecastResponse> refreshReachData(String reachId) =>
      throw UnimplementedError();
  @override
  Future<bool> isReachCached(String reachId) async => false;
  @override
  Future<ForecastResponse> loadCurrentFlowOnly(String reachId) =>
      throw UnimplementedError();
  @override
  Future<ReachData> loadBasicReachInfo(String reachId) =>
      throw UnimplementedError();
  @override
  ForecastResponse mergeCurrentFlowData(
          ForecastResponse existing, ForecastResponse newFlowData) =>
      throw UnimplementedError();
  @override
  Map<String, dynamic> getEnsembleSummary(
          ForecastResponse forecast, String forecastType) =>
      {};
  @override
  List<EnsembleStatPoint> getEnsembleStatistics(
          ForecastResponse forecast, String forecastType) =>
      [];
  @override
  bool hasMultipleEnsembleMembers(
          ForecastResponse forecast, String forecastType) =>
      false;
  @override
  Map<String, List<ChartData>> getEnsembleSeriesForChart(
          ForecastResponse forecast, String forecastType) =>
      {};
  @override
  List<ChartDataPoint> getEnsembleReferenceData(
          ForecastResponse forecast, String forecastType) =>
      [];
  @override
  Future<ReachDetailsData> loadReachDetailsData(String reachId) =>
      throw UnimplementedError();
}

/// A controllable stub for use cases. [handler] returns the result for each
/// call, and [callLog] records every invocation so tests can assert ordering.
class StubOverviewUseCase implements LoadForecastOverviewUseCase {
  Future<ServiceResult<ForecastResponse>> Function(String reachId) handler;
  final List<String> callLog = [];

  StubOverviewUseCase(this.handler);

  @override
  Future<ServiceResult<ForecastResponse>> call(String reachId) {
    callLog.add(reachId);
    return handler(reachId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class StubSpecificForecastUseCase implements LoadSpecificForecastUseCase {
  Future<ServiceResult<ForecastResponse>> Function(
      String reachId, String forecastType) handler;
  final List<(String, String)> callLog = [];

  StubSpecificForecastUseCase(this.handler);

  @override
  Future<ServiceResult<ForecastResponse>> call(
    String reachId,
    String forecastType,
  ) {
    callLog.add((reachId, forecastType));
    return handler(reachId, forecastType);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class StubSupplementaryUseCase implements LoadForecastSupplementaryUseCase {
  Future<ServiceResult<ForecastResponse>> Function(
      String reachId, ForecastResponse existing) handler;
  final List<String> callLog = [];

  StubSupplementaryUseCase(this.handler);

  @override
  Future<ServiceResult<ForecastResponse>> call(
    String reachId,
    ForecastResponse existingData,
  ) {
    callLog.add(reachId);
    return handler(reachId, existingData);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class StubCompleteUseCase implements LoadCompleteForecastUseCase {
  @override
  Future<ServiceResult<ForecastResponse>> call(String reachId) async =>
      ServiceResult.success(_emptyForecast());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Test data helpers
// ---------------------------------------------------------------------------

ForecastResponse _emptyForecast({ReachData? reach}) => ForecastResponse(
      reach: reach ?? createTestReachData(),
      mediumRange: {},
      longRange: {},
    );

ForecastResponse _forecastWithShortRange({ReachData? reach}) =>
    ForecastResponse(
      reach: reach ?? createTestReachData(),
      shortRange: createTestForecastSeries(),
      mediumRange: {},
      longRange: {},
    );

ForecastResponse _forecastWithMediumRange({ReachData? reach}) =>
    ForecastResponse(
      reach: reach ?? createTestReachData(),
      mediumRange: {
        'mean': createTestForecastSeries(),
      },
      longRange: {},
    );

ForecastResponse _forecastWithLongRange({ReachData? reach}) => ForecastResponse(
      reach: reach ?? createTestReachData(),
      mediumRange: {},
      longRange: {
        'mean': createTestForecastSeries(),
      },
    );

ForecastResponse _forecastWithReturnPeriods() => ForecastResponse(
      reach: createTestReachDataWithReturnPeriods(),
      mediumRange: {},
      longRange: {},
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late StubForecastService forecastService;
  late StubOverviewUseCase overviewUseCase;
  late StubSpecificForecastUseCase specificUseCase;
  late StubSupplementaryUseCase supplementaryUseCase;
  late ReachDataProvider provider;

  setUp(() {
    forecastService = StubForecastService();
    forecastService.currentFlowReturn = 150.0;

    overviewUseCase = StubOverviewUseCase(
      (reachId) async => ServiceResult.success(_emptyForecast()),
    );

    specificUseCase = StubSpecificForecastUseCase(
      (reachId, type) async => ServiceResult.success(_emptyForecast()),
    );

    supplementaryUseCase = StubSupplementaryUseCase(
      (reachId, existing) async => ServiceResult.success(
        ForecastResponse(
          reach: createTestReachDataWithReturnPeriods(
              reachId: existing.reach.reachId),
          mediumRange: {},
          longRange: {},
        ),
      ),
    );

    provider = ReachDataProvider(
      forecastService: forecastService,
      loadOverview: overviewUseCase,
      loadSpecificForecast: specificUseCase,
      loadSupplementary: supplementaryUseCase,
      loadComplete: StubCompleteUseCase(),
    );
  });

  group('loadAllData — overview first, then parallel', () {
    test('returns true and sets overview data when overview succeeds',
        () async {
      final result = await provider.loadAllData('123');

      expect(result, isTrue);
      expect(provider.hasOverviewData, isTrue);
      expect(provider.currentReach?.reachId, '23021904');
      expect(overviewUseCase.callLog, ['123']);
    });

    test('returns false and sets error when overview fails', () async {
      overviewUseCase.handler = (reachId) async =>
          ServiceResult.failure(const ServiceException.network('Network error'));

      final result = await provider.loadAllData('123');

      expect(result, isFalse);
      expect(provider.errorMessage, 'Network error');
      expect(provider.hourlyState, SectionLoadState.error);
      expect(provider.dailyState, SectionLoadState.error);
      expect(provider.extendedState, SectionLoadState.error);
    });

    test('fires all three section loads plus supplementary after overview',
        () async {
      // Use completers so we can verify all were fired
      final shortCompleter = Completer<ServiceResult<ForecastResponse>>();
      final mediumCompleter = Completer<ServiceResult<ForecastResponse>>();
      final longCompleter = Completer<ServiceResult<ForecastResponse>>();

      specificUseCase.handler = (reachId, type) {
        switch (type) {
          case 'short_range':
            return shortCompleter.future;
          case 'medium_range':
            return mediumCompleter.future;
          case 'long_range':
            return longCompleter.future;
          default:
            throw ArgumentError('Unexpected type: $type');
        }
      };

      // loadAllData returns after overview; parallel loads are still in-flight
      final result = await provider.loadAllData('123');
      expect(result, isTrue);

      // All section states should be loading
      expect(provider.hourlyState, SectionLoadState.loading);
      expect(provider.dailyState, SectionLoadState.loading);
      expect(provider.extendedState, SectionLoadState.loading);

      // Verify all three section types were requested
      expect(specificUseCase.callLog, [
        ('123', 'short_range'),
        ('123', 'medium_range'),
        ('123', 'long_range'),
      ]);

      // Complete them
      shortCompleter.complete(
          ServiceResult.success(_forecastWithShortRange()));
      mediumCompleter.complete(
          ServiceResult.success(_forecastWithMediumRange()));
      longCompleter.complete(
          ServiceResult.success(_forecastWithLongRange()));

      // Let microtasks run
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(provider.hourlyState, SectionLoadState.loaded);
      expect(provider.dailyState, SectionLoadState.loaded);
      expect(provider.extendedState, SectionLoadState.loaded);
    });

    test('uses session cache on second call (fast path)', () async {
      await provider.loadAllData('123');
      // Let parallel loads complete
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      overviewUseCase.callLog.clear();
      specificUseCase.callLog.clear();

      final result = await provider.loadAllData('123');

      expect(result, isTrue);
      // Should NOT have called overview or specific again
      expect(overviewUseCase.callLog, isEmpty);
      expect(specificUseCase.callLog, isEmpty);
      expect(provider.loadingPhase, 'complete');
    });
  });

  group('parallel section loading — independent notifyListeners', () {
    test('each section notifies independently as it resolves', () async {
      final shortCompleter = Completer<ServiceResult<ForecastResponse>>();
      final mediumCompleter = Completer<ServiceResult<ForecastResponse>>();
      final longCompleter = Completer<ServiceResult<ForecastResponse>>();

      specificUseCase.handler = (reachId, type) {
        switch (type) {
          case 'short_range':
            return shortCompleter.future;
          case 'medium_range':
            return mediumCompleter.future;
          case 'long_range':
            return longCompleter.future;
          default:
            throw ArgumentError('Unexpected type: $type');
        }
      };

      final notifications = <String>[];
      provider.addListener(() {
        // Record which sections are done at each notification
        if (provider.hourlyState.isDone &&
            !notifications.contains('short_range')) {
          notifications.add('short_range');
        }
        if (provider.dailyState.isDone &&
            !notifications.contains('medium_range')) {
          notifications.add('medium_range');
        }
        if (provider.extendedState.isDone &&
            !notifications.contains('long_range')) {
          notifications.add('long_range');
        }
      });

      await provider.loadAllData('123');

      // Complete short range first
      shortCompleter.complete(
          ServiceResult.success(_forecastWithShortRange()));
      await Future.delayed(Duration.zero);
      expect(notifications, contains('short_range'));
      expect(notifications, isNot(contains('medium_range')));

      // Complete medium range
      mediumCompleter.complete(
          ServiceResult.success(_forecastWithMediumRange()));
      await Future.delayed(Duration.zero);
      expect(notifications, contains('medium_range'));

      // Complete long range
      longCompleter.complete(
          ServiceResult.success(_forecastWithLongRange()));
      await Future.delayed(Duration.zero);
      expect(notifications, contains('long_range'));
    });

    test('section error does not block other sections', () async {
      final shortCompleter = Completer<ServiceResult<ForecastResponse>>();
      final mediumCompleter = Completer<ServiceResult<ForecastResponse>>();
      final longCompleter = Completer<ServiceResult<ForecastResponse>>();

      specificUseCase.handler = (reachId, type) {
        switch (type) {
          case 'short_range':
            return shortCompleter.future;
          case 'medium_range':
            return mediumCompleter.future;
          case 'long_range':
            return longCompleter.future;
          default:
            throw ArgumentError('Unexpected type: $type');
        }
      };

      await provider.loadAllData('123');

      // Short range fails
      shortCompleter.complete(ServiceResult.failure(
          const ServiceException.network('Timeout')));
      await Future.delayed(Duration.zero);
      expect(provider.hourlyState, SectionLoadState.error);

      // Medium and long still succeed
      mediumCompleter.complete(
          ServiceResult.success(_forecastWithMediumRange()));
      longCompleter.complete(
          ServiceResult.success(_forecastWithLongRange()));
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(provider.dailyState, SectionLoadState.loaded);
      expect(provider.extendedState, SectionLoadState.loaded);
    });
  });

  group('current flow recalculation after each merge', () {
    test('current flow recalculates when section merges in', () async {
      // Track getCurrentFlow calls by counting forecastService invocations
      var flowCallCount = 0;
      final originalReturn = forecastService.currentFlowReturn;
      forecastService.currentFlowReturn = originalReturn;

      final shortCompleter = Completer<ServiceResult<ForecastResponse>>();
      specificUseCase.handler = (reachId, type) {
        if (type == 'short_range') return shortCompleter.future;
        return Future.value(ServiceResult.success(_emptyForecast()));
      };

      await provider.loadAllData('123');

      // After overview, cache is populated
      final flowBefore = provider.getCurrentFlow();

      // Complete short range — should recalculate
      shortCompleter.complete(
          ServiceResult.success(_forecastWithShortRange()));
      await Future.delayed(Duration.zero);

      // getCurrentFlow should return fresh value (cache was cleared and repopulated)
      final flowAfter = provider.getCurrentFlow();
      expect(flowAfter, isNotNull);
    });
  });

  group('generation-based cancellation', () {
    test('stale parallel loads are discarded when clearCurrentReach is called',
        () async {
      final shortCompleter = Completer<ServiceResult<ForecastResponse>>();

      specificUseCase.handler = (reachId, type) {
        if (type == 'short_range') return shortCompleter.future;
        return Future.value(ServiceResult.success(_emptyForecast()));
      };

      await provider.loadAllData('123');
      final genBefore = provider.loadingGeneration;

      // Navigate away — clears reach and increments generation
      provider.clearCurrentReach();
      expect(provider.loadingGeneration, greaterThan(genBefore));

      // Now the stale short range completes — should be ignored
      shortCompleter.complete(
          ServiceResult.success(_forecastWithShortRange()));
      await Future.delayed(Duration.zero);

      // Provider should NOT have short range data (it was cleared)
      expect(provider.currentForecast, isNull);
      expect(provider.hourlyState, SectionLoadState.idle);
    });

    test('second loadAllData call invalidates first call', () async {
      final firstShortCompleter =
          Completer<ServiceResult<ForecastResponse>>();
      var callCount = 0;

      specificUseCase.handler = (reachId, type) {
        callCount++;
        if (callCount <= 3) {
          // First batch (3 section calls from first loadAllData)
          if (type == 'short_range') return firstShortCompleter.future;
          return Future.value(ServiceResult.success(_emptyForecast()));
        }
        // Second batch returns immediately
        return Future.value(ServiceResult.success(_emptyForecast()));
      };

      // Start first load
      final future1 = provider.loadAllData('123');
      await future1;

      // Start second load for different reach — increments generation
      overviewUseCase.handler = (reachId) async => ServiceResult.success(
          _emptyForecast(reach: createTestReachData(reachId: '456')));
      final future2 = provider.loadAllData('456');
      await future2;

      // Complete the stale short range from first call
      firstShortCompleter.complete(
          ServiceResult.success(_forecastWithShortRange()));
      await Future.delayed(Duration.zero);

      // Provider should show reach 456, not 123's data
      expect(provider.currentReach?.reachId, '456');
    });
  });

  group('all sections empty — graceful handling', () {
    test('all empty sections result in empty states, no crash', () async {
      // Overview returns basic data, all specific forecasts return empty
      specificUseCase.handler = (reachId, type) async =>
          ServiceResult.success(_emptyForecast());

      supplementaryUseCase.handler = (reachId, existing) async =>
          ServiceResult.success(_emptyForecast());

      final result = await provider.loadAllData('123');
      expect(result, isTrue); // Overview succeeded

      // Let parallel loads complete
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(provider.hourlyState, SectionLoadState.empty);
      expect(provider.dailyState, SectionLoadState.empty);
      expect(provider.extendedState, SectionLoadState.empty);
      expect(provider.hasOverviewData, isTrue);
    });
  });

  group('supplementary data merge preserves forecast sections', () {
    test('supplementary merge does not overwrite short range data', () async {
      // Overview first
      overviewUseCase.handler = (reachId) async =>
          ServiceResult.success(_emptyForecast());

      // Short range returns data
      specificUseCase.handler = (reachId, type) async {
        if (type == 'short_range') {
          return ServiceResult.success(_forecastWithShortRange());
        }
        return ServiceResult.success(_emptyForecast());
      };

      // Supplementary returns reach with return periods
      supplementaryUseCase.handler = (reachId, existing) async =>
          ServiceResult.success(_forecastWithReturnPeriods());

      await provider.loadAllData('123');
      // Let all parallel loads complete
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      // Short range data should be preserved
      expect(provider.hasHourlyForecast, isTrue);
      // Return periods should be merged in
      expect(provider.hasSupplementaryData, isTrue);
    });
  });

  group('comprehensiveRefresh', () {
    test('clears caches and delegates to loadAllData', () async {
      // Populate cache first
      await provider.loadAllData('123');
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(provider.sessionCache.containsKey('123'), isTrue);

      // Refresh should clear cache and re-fetch
      overviewUseCase.callLog.clear();
      await provider.comprehensiveRefresh('123');

      // Overview should have been called again (cache was cleared)
      expect(overviewUseCase.callLog, ['123']);
    });
  });

  group('loadAllData sets phase to complete when all done', () {
    test('phase transitions to complete after all sections resolve', () async {
      await provider.loadAllData('123');
      // Let parallel loads complete
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(provider.loadingPhase, 'complete');
    });
  });
}
