import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivr/services/4_infrastructure/api/noaa_api_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';

/// Minimal stub for flow unit preference service.
class _StubFlowUnitService implements IFlowUnitPreferenceService {
  @override
  String get currentFlowUnit => 'CFS';
  @override
  void setFlowUnit(String unit) {}
  @override
  String normalizeUnit(String unit) => unit.toUpperCase();
  @override
  double convertFlow(double value, String fromUnit, String toUnit) => value;
  @override
  double convertToPreferredUnit(double value, String fromUnit) => value;
  @override
  double convertFromPreferredUnit(double value, String toUnit) => value;
  @override
  String getDisplayUnit() => 'CFS';
  @override
  bool get isCFS => true;
  @override
  bool get isCMS => false;
  @override
  void resetToDefault() {}
}

void main() {
  group('ApiException', () {
    test('stores message', () {
      const exception = ApiException('Something went wrong');
      expect(exception.message, 'Something went wrong');
    });

    test('toString includes ApiException prefix', () {
      const exception = ApiException('Network error');
      expect(exception.toString(), 'ApiException: Network error');
    });

    test('can be caught as Exception', () {
      expect(
        () => throw const ApiException('test'),
        throwsA(isA<ApiException>()),
      );
    });

    test('can be caught as generic Exception type', () {
      Object? caught;
      try {
        throw const ApiException('test error');
      } on Exception catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught, isA<ApiException>());
      expect((caught as ApiException).message, 'test error');
    });

    test('handles empty message', () {
      const exception = ApiException('');
      expect(exception.message, '');
      expect(exception.toString(), 'ApiException: ');
    });
  });

  group('NoaaApiService retry logic', () {
    late _StubFlowUnitService unitService;

    setUp(() {
      unitService = _StubFlowUnitService();
    });

    test('succeeds on first attempt with 200 response', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return http.Response(
          jsonEncode({
            'reachId': '12345',
            'name': 'Test River',
            'state': 'UT',
            'city': 'Provo',
          }),
          200,
        );
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      final result = await service.fetchReachInfo('12345');
      expect(result['reachId'], '12345');
      expect(callCount, 1);
    });

    test('retries on 500 server error and succeeds on second attempt', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          return http.Response('Internal Server Error', 500);
        }
        return http.Response(
          jsonEncode({
            'reachId': '12345',
            'name': 'Test River',
            'state': 'UT',
            'city': 'Provo',
          }),
          200,
        );
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      final result = await service.fetchReachInfo('12345');
      expect(result['reachId'], '12345');
      expect(callCount, 2);
    });

    test('retries on timeout and succeeds on second attempt', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          throw TimeoutException('Connection timed out');
        }
        return http.Response(
          jsonEncode({
            'reachId': '12345',
            'name': 'Test River',
            'state': 'UT',
            'city': 'Provo',
          }),
          200,
        );
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      final result = await service.fetchReachInfo('12345');
      expect(result['reachId'], '12345');
      expect(callCount, 2);
    });

    test('throws after exhausting all retries on timeout', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        throw TimeoutException('Connection timed out');
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      await expectLater(
        service.fetchReachInfo('12345'),
        throwsA(isA<ServiceException>()),
      );
      // 1 initial + 2 retries = 3 total attempts
      expect(callCount, 3);
    });

    test('returns 500 response after exhausting retries on persistent server error', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return http.Response('Internal Server Error', 500);
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      // After 3 attempts all returning 500, the last 500 is returned
      // and fetchReachInfo throws because status != 200
      await expectLater(
        service.fetchReachInfo('12345'),
        throwsA(isA<ServiceException>()),
      );
      expect(callCount, 3);
    });

    test('does not retry on 400 client error', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return http.Response('Bad Request', 400);
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      await expectLater(
        service.fetchReachInfo('12345'),
        throwsA(isA<ServiceException>()),
      );
      // Should NOT retry on 4xx — only 5xx triggers retry
      expect(callCount, 1);
    });

    test('does not retry on 404 not found', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return http.Response('Not Found', 404);
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      await expectLater(
        service.fetchReachInfo('12345'),
        throwsA(isA<ServiceException>()),
      );
      expect(callCount, 1);
    });

    test('completes in bounded time (no infinite recursion)', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return http.Response('Server Error', 503);
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      // This test guards against the infinite recursion bug.
      // With maxRetries=2, we expect exactly 3 calls and completion
      // within a reasonable time (not a stack overflow).
      await expectLater(
        service.fetchReachInfo('12345').timeout(
          const Duration(seconds: 30),
        ),
        throwsA(isA<ServiceException>()),
      );
      expect(callCount, 3);
    });
  });

  group('NoaaApiService empty-data fallback', () {
    late _StubFlowUnitService unitService;

    /// A minimal valid forecast response with actual data in shortRange.
    Map<String, dynamic> _fullResponse() => {
          'reach': {'reachId': '12345', 'name': 'Test River'},
          'shortRange': {
            'series': {
              'referenceTime': '2026-04-07T12:00:00Z',
              'units': 'CFS',
              'data': [
                {'validTime': '2026-04-07T13:00:00Z', 'flow': 100.0},
              ],
            },
          },
          'mediumRange': {
            'mean': {
              'referenceTime': '2026-04-07T12:00:00Z',
              'units': 'CFS',
              'data': [
                {'validTime': '2026-04-07T13:00:00Z', 'flow': 120.0},
              ],
            },
          },
          'longRange': {
            'mean': {
              'referenceTime': '2026-04-07T12:00:00Z',
              'units': 'CFS',
              'data': [
                {'validTime': '2026-04-07T13:00:00Z', 'flow': 130.0},
              ],
            },
          },
          'mediumRangeBlend': {},
          'analysisAssimilation': {},
        };

    /// A response where the filtered section has the structure but empty data arrays.
    Map<String, dynamic> _emptyMediumRangeFilteredResponse() => {
          'reach': {'reachId': '12345', 'name': 'Test River'},
          'shortRange': {},
          'mediumRange': {
            'mean': {
              'referenceTime': null,
              'units': 'CFS',
              'data': [],
            },
            'member1': {
              'referenceTime': null,
              'units': 'CFS',
              'data': [],
            },
          },
          'longRange': {},
          'mediumRangeBlend': {},
          'analysisAssimilation': {},
        };

    Map<String, dynamic> _emptyShortRangeFilteredResponse() => {
          'reach': {'reachId': '12345', 'name': 'Test River'},
          'shortRange': {
            'series': {
              'referenceTime': null,
              'units': 'CFS',
              'data': [],
            },
          },
          'mediumRange': {},
          'longRange': {},
          'mediumRangeBlend': {},
          'analysisAssimilation': {},
        };

    setUp(() {
      unitService = _StubFlowUnitService();
    });

    test('returns filtered data when section has real data (no fallback)', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        // Filtered endpoint returns valid data
        return http.Response(jsonEncode(_fullResponse()), 200);
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      final result = await service.fetchForecast('12345', 'medium_range');
      expect(result['mediumRange'], isNotNull);
      // Only the filtered call — no fallback
      expect(callCount, 1);
    });

    test('falls back to unfiltered when medium_range has empty data', () async {
      final requestUrls = <String>[];
      final client = MockClient((request) async {
        requestUrls.add(request.url.toString());
        if (request.url.queryParameters.containsKey('series')) {
          // Filtered endpoint returns empty data
          return http.Response(
            jsonEncode(_emptyMediumRangeFilteredResponse()),
            200,
          );
        } else {
          // Unfiltered endpoint returns full data
          return http.Response(jsonEncode(_fullResponse()), 200);
        }
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      final result = await service.fetchForecast('12345', 'medium_range');

      // Should have called filtered first, then unfiltered
      expect(requestUrls.length, greaterThanOrEqualTo(2));
      expect(requestUrls.first, contains('series=medium_range'));
      expect(requestUrls.last, isNot(contains('series=')));

      // Should have real data from unfiltered fallback
      final mediumRange = result['mediumRange'] as Map<String, dynamic>;
      final mean = mediumRange['mean'] as Map<String, dynamic>;
      final data = mean['data'] as List;
      expect(data, isNotEmpty);
    });

    test('falls back to unfiltered when short_range has empty data', () async {
      final requestUrls = <String>[];
      final client = MockClient((request) async {
        requestUrls.add(request.url.toString());
        if (request.url.queryParameters.containsKey('series')) {
          return http.Response(
            jsonEncode(_emptyShortRangeFilteredResponse()),
            200,
          );
        } else {
          return http.Response(jsonEncode(_fullResponse()), 200);
        }
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      final result = await service.fetchForecast('12345', 'short_range');

      expect(requestUrls.length, greaterThanOrEqualTo(2));
      expect(requestUrls.first, contains('series=short_range'));

      final shortRange = result['shortRange'] as Map<String, dynamic>;
      final series = shortRange['series'] as Map<String, dynamic>;
      final data = series['data'] as List;
      expect(data, isNotEmpty);
    });

    test('unfiltered cache is reused for multiple fallbacks in same cycle', () async {
      var unfilteredCallCount = 0;
      final client = MockClient((request) async {
        if (request.url.queryParameters.containsKey('series')) {
          // All filtered endpoints return empty data
          return http.Response(
            jsonEncode(_emptyMediumRangeFilteredResponse()),
            200,
          );
        } else {
          unfilteredCallCount++;
          return http.Response(jsonEncode(_fullResponse()), 200);
        }
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      // Two fallbacks for the same reach
      await service.fetchForecast('12345', 'medium_range');
      await service.fetchForecast('12345', 'long_range');

      // Unfiltered endpoint should only be called once (cached)
      expect(unfilteredCallCount, 1);
    });

    test('returns empty result when both filtered and unfiltered have no data', () async {
      final emptyResponse = {
        'reach': {'reachId': '12345', 'name': 'Test River'},
        'shortRange': {},
        'mediumRange': {
          'mean': {'referenceTime': null, 'units': 'CFS', 'data': []},
        },
        'longRange': {},
        'mediumRangeBlend': {},
        'analysisAssimilation': {},
      };

      final client = MockClient((request) async {
        return http.Response(jsonEncode(emptyResponse), 200);
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      // Should not throw — returns the empty response gracefully
      final result = await service.fetchForecast('12345', 'medium_range');
      expect(result, isNotNull);
    });

    test('fetchAllForecasts uses unfiltered endpoint primarily', () async {
      final requestUrls = <String>[];
      final client = MockClient((request) async {
        requestUrls.add(request.url.toString());
        return http.Response(jsonEncode(_fullResponse()), 200);
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      await service.fetchAllForecasts('12345');

      // Should use the unfiltered endpoint (no ?series= param)
      expect(requestUrls.length, 1);
      expect(requestUrls.first, isNot(contains('series=')));
      expect(requestUrls.first, contains('/streamflow'));
    });

    test('fetchAllForecasts falls back to filtered when unfiltered fails', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        if (!request.url.queryParameters.containsKey('series')) {
          // Unfiltered endpoint fails
          return http.Response('Service Unavailable', 503);
        }
        // Filtered endpoints succeed
        return http.Response(jsonEncode(_fullResponse()), 200);
      });

      final service = NoaaApiService(
        client: client,
        unitService: unitService,
      );

      final result = await service.fetchAllForecasts('12345');
      expect(result, isNotNull);
      // 3 retries for unfiltered (1 + 2 retries) + 3 filtered calls
      expect(callCount, greaterThan(3));
    });
  });
}
