import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/core/models/reach_data.dart';

import '../../helpers/fake_data.dart';

void main() {
  group('ReachData', () {
    group('constructor', () {
      test('creates instance with required fields', () {
        final reach = createTestReachData();

        expect(reach.reachId, '23021904');
        expect(reach.riverName, 'Deep Creek');
        expect(reach.latitude, 47.6588);
        expect(reach.longitude, -117.4260);
        expect(reach.availableForecasts, hasLength(4));
        expect(reach.isPartiallyLoaded, false);
      });
    });

    group('fromNoaaApi', () {
      test('parses valid API response', () {
        final json = createTestNoaaApiResponse();
        final reach = ReachData.fromNoaaApi(json);

        expect(reach.reachId, '23021904');
        expect(reach.riverName, 'Deep Creek');
        expect(reach.latitude, 47.6588);
        expect(reach.longitude, -117.4260);
        expect(reach.availableForecasts, ['short_range', 'medium_range']);
        expect(reach.isPartiallyLoaded, false);
      });

      test('trims whitespace from reachId', () {
        final json = createTestNoaaApiResponse(reachId: '  23021904  ');
        final reach = ReachData.fromNoaaApi(json);
        expect(reach.reachId, '23021904');
      });

      test('parses upstream and downstream routes', () {
        final json = createTestNoaaApiResponse(
          route: {
            'upstream': [
              {'reachId': '23021906'},
              {'reachId': '23023198'},
            ],
            'downstream': [
              {'reachId': '23022058'},
            ],
          },
        );
        final reach = ReachData.fromNoaaApi(json);

        expect(reach.upstreamReaches, ['23021906', '23023198']);
        expect(reach.downstreamReaches, ['23022058']);
      });

      test('handles missing route gracefully', () {
        final json = createTestNoaaApiResponse();
        final reach = ReachData.fromNoaaApi(json);

        expect(reach.upstreamReaches, isNull);
        expect(reach.downstreamReaches, isNull);
      });

      test('throws FormatException on invalid data', () {
        expect(
          () => ReachData.fromNoaaApi({'invalid': 'data'}),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('fromReturnPeriodApi', () {
      test('parses return period response', () {
        final json = createTestReturnPeriodApiResponse();
        final reach = ReachData.fromReturnPeriodApi(json);

        expect(reach.reachId, '23021904');
        expect(reach.returnPeriods, isNotNull);
        expect(reach.returnPeriods![2], 3518.03);
        expect(reach.returnPeriods![5], 6119.41);
        expect(reach.returnPeriods![10], 7841.75);
        expect(reach.returnPeriods![25], 10200.50);
        expect(reach.isPartiallyLoaded, true);
      });

      test('throws FormatException on empty array', () {
        expect(
          () => ReachData.fromReturnPeriodApi([]),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('toJson / fromJson roundtrip', () {
      test('serializes and deserializes correctly', () {
        final original = createTestReachData(
          returnPeriods: {2: 100.0, 5: 200.0},
          upstreamReaches: ['123', '456'],
          customName: 'My Creek',
        );

        final json = original.toJson();
        final restored = ReachData.fromJson(json);

        expect(restored.reachId, original.reachId);
        expect(restored.riverName, original.riverName);
        expect(restored.latitude, original.latitude);
        expect(restored.longitude, original.longitude);
        expect(restored.city, original.city);
        expect(restored.state, original.state);
        expect(restored.availableForecasts, original.availableForecasts);
        expect(restored.returnPeriods, original.returnPeriods);
        expect(restored.upstreamReaches, original.upstreamReaches);
        expect(restored.customName, original.customName);
        expect(restored.isPartiallyLoaded, original.isPartiallyLoaded);
      });

      test('handles null optional fields', () {
        final original = createTestReachData(
          city: null,
          state: null,
          returnPeriods: null,
          upstreamReaches: null,
          customName: null,
        );

        final json = original.toJson();
        final restored = ReachData.fromJson(json);

        expect(restored.city, isNull);
        expect(restored.state, isNull);
        expect(restored.returnPeriods, isNull);
        expect(restored.upstreamReaches, isNull);
        expect(restored.customName, isNull);
      });
    });

    group('mergeWith', () {
      test('prefers non-empty values from primary', () {
        final primary = createTestReachData(riverName: 'Deep Creek');
        final secondary = createTestReachData(
          riverName: 'Other Creek',
          returnPeriods: {2: 100.0},
        );

        final merged = primary.mergeWith(secondary);

        expect(merged.riverName, 'Deep Creek');
        expect(merged.returnPeriods, {2: 100.0});
        expect(merged.isPartiallyLoaded, false);
      });

      test('fills in missing data from other', () {
        final primary = createTestReachData(
          city: null,
          state: null,
          returnPeriods: null,
        );
        final secondary = createTestReachData(
          city: 'Portland',
          state: 'OR',
          returnPeriods: {2: 100.0},
        );

        final merged = primary.mergeWith(secondary);

        expect(merged.city, 'Portland');
        expect(merged.state, 'OR');
        expect(merged.returnPeriods, {2: 100.0});
      });
    });

    group('copyWith', () {
      test('creates copy with updated fields', () {
        final original = createTestReachData();
        final copy = original.copyWith(
          customName: 'Renamed Creek',
          city: 'Portland',
        );

        expect(copy.customName, 'Renamed Creek');
        expect(copy.city, 'Portland');
        expect(copy.reachId, original.reachId);
        expect(copy.riverName, original.riverName);
      });

      test('preserves original when no changes', () {
        final original = createTestReachData(customName: 'Test');
        final copy = original.copyWith();

        expect(copy.customName, 'Test');
        expect(copy.reachId, original.reachId);
      });
    });

    group('helper properties', () {
      test('displayName returns customName when set', () {
        final reach = createTestReachData(customName: 'My Creek');
        expect(reach.displayName, 'My Creek');
      });

      test('displayName returns riverName when no customName', () {
        final reach = createTestReachData(customName: null);
        expect(reach.displayName, 'Deep Creek');
      });

      test('hasCustomName is true when customName is set and non-empty', () {
        expect(createTestReachData(customName: 'Test').hasCustomName, true);
        expect(createTestReachData(customName: null).hasCustomName, false);
        expect(createTestReachData(customName: '').hasCustomName, false);
      });

      test('formattedLocation returns city, state', () {
        final reach = createTestReachData(city: 'Spokane', state: 'WA');
        expect(reach.formattedLocation, 'Spokane, WA');
      });

      test('formattedLocation returns empty when missing', () {
        final reach = createTestReachData(city: null, state: null);
        expect(reach.formattedLocation, '');
      });

      test('formattedLocationSubtitle falls back to coordinates', () {
        final reach = createTestReachData(city: null, state: null);
        expect(reach.formattedLocationSubtitle, '47.6588, -117.4260');
      });

      test('hasReturnPeriods checks for non-null non-empty map', () {
        expect(createTestReachData(returnPeriods: null).hasReturnPeriods, false);
        expect(createTestReachData(returnPeriods: {}).hasReturnPeriods, false);
        expect(
          createTestReachData(returnPeriods: {2: 100.0}).hasReturnPeriods,
          true,
        );
      });

      test('hasLocationData checks for non-default values', () {
        expect(createTestReachData().hasLocationData, true);
        expect(
          createTestReachData(latitude: 0.0, longitude: 0.0).hasLocationData,
          false,
        );
        expect(
          createTestReachData(riverName: 'Unknown').hasLocationData,
          false,
        );
      });
    });

    group('equality', () {
      test('two ReachData with same reachId are equal', () {
        final a = createTestReachData(reachId: '123');
        final b = createTestReachData(reachId: '123', riverName: 'Other');
        expect(a, equals(b));
      });

      test('two ReachData with different reachId are not equal', () {
        final a = createTestReachData(reachId: '123');
        final b = createTestReachData(reachId: '456');
        expect(a, isNot(equals(b)));
      });

      test('hashCode is based on reachId', () {
        final a = createTestReachData(reachId: '123');
        final b = createTestReachData(reachId: '123');
        expect(a.hashCode, equals(b.hashCode));
      });
    });
  });

  group('ForecastPoint', () {
    test('fromJson parses correctly', () {
      final json = {
        'validTime': '2025-06-15T12:00:00.000',
        'flow': 150.5,
      };
      final point = ForecastPoint.fromJson(json);

      expect(point.validTime, DateTime(2025, 6, 15, 12, 0));
      expect(point.flow, 150.5);
    });

    test('toJson serializes correctly', () {
      final point = createTestForecastPoint(
        validTime: DateTime(2025, 6, 15, 12, 0),
        flow: 150.5,
      );
      final json = point.toJson();

      expect(json['validTime'], '2025-06-15T12:00:00.000');
      expect(json['flow'], 150.5);
    });
  });

  group('ForecastSeries', () {
    group('fromJson / toJson roundtrip', () {
      test('serializes and deserializes correctly', () {
        final original = createTestForecastSeries(
          referenceTime: DateTime(2025, 6, 15, 6, 0),
          units: 'CMS',
        );

        final json = original.toJson();
        final restored = ForecastSeries.fromJson(json);

        expect(restored.units, 'CMS');
        expect(restored.data.length, 3);
        expect(restored.referenceTime, DateTime(2025, 6, 15, 6, 0));
      });

      test('handles null referenceTime', () {
        final series = ForecastSeries(
          units: 'CFS',
          data: [createTestForecastPoint()],
        );

        final json = series.toJson();
        final restored = ForecastSeries.fromJson(json);

        expect(restored.referenceTime, isNull);
      });
    });

    group('isEmpty / isNotEmpty', () {
      test('isEmpty is true for empty data', () {
        final series = ForecastSeries(units: 'CMS', data: []);
        expect(series.isEmpty, true);
        expect(series.isNotEmpty, false);
      });

      test('isNotEmpty is true for non-empty data', () {
        final series = createTestForecastSeries();
        expect(series.isEmpty, false);
        expect(series.isNotEmpty, true);
      });
    });

    group('getFlowAt', () {
      test('returns closest flow to given time', () {
        final series = createTestForecastSeries();
        final flow = series.getFlowAt(DateTime(2025, 6, 15, 11, 30));

        // 11:30 is between 11:00 (120) and 12:00 (150), but 11:00 is closer
        expect(flow, 120.0);
      });

      test('returns null for empty series', () {
        final series = ForecastSeries(units: 'CMS', data: []);
        expect(series.getFlowAt(DateTime.now()), isNull);
      });
    });

    group('withPreferredUnits', () {
      test('skips conversion when units already match', () {
        final data = [
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 12), flow: 100.0),
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 13), flow: 200.0),
        ];

        final result = ForecastSeries.withPreferredUnits(
          originalUnits: 'CFS',
          preferredUnits: 'CFS',
          originalData: data,
          referenceTime: DateTime.utc(2025, 6, 15),
        );

        expect(result.units, 'CFS');
        expect(result.data.length, 2);
        expect(result.data[0].flow, 100.0);
        expect(result.data[1].flow, 200.0);
      });

      test('skips conversion for normalized equivalent units (cfs vs CFS)', () {
        final data = [
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 12), flow: 100.0),
        ];

        final result = ForecastSeries.withPreferredUnits(
          originalUnits: 'cfs',
          preferredUnits: 'CFS',
          originalData: data,
        );

        // Should NOT convert since cfs normalizes to CFS
        expect(result.data[0].flow, 100.0);
      });

      test('converts CMS to CFS correctly', () {
        final data = [
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 12), flow: 1.0),
        ];

        final result = ForecastSeries.withPreferredUnits(
          originalUnits: 'CMS',
          preferredUnits: 'CFS',
          originalData: data,
        );

        expect(result.units, 'CFS');
        // 1 CMS = 35.3147 CFS
        expect(result.data[0].flow, closeTo(35.3147, 0.01));
      });

      test('converts CFS to CMS correctly', () {
        final data = [
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 12), flow: 35.3147),
        ];

        final result = ForecastSeries.withPreferredUnits(
          originalUnits: 'CFS',
          preferredUnits: 'CMS',
          originalData: data,
        );

        expect(result.units, 'CMS');
        expect(result.data[0].flow, closeTo(1.0, 0.01));
      });

      test('preserves referenceTime', () {
        final refTime = DateTime.utc(2025, 6, 15, 6, 0);
        final data = [
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 12), flow: 100.0),
        ];

        final result = ForecastSeries.withPreferredUnits(
          originalUnits: 'CMS',
          preferredUnits: 'CFS',
          originalData: data,
          referenceTime: refTime,
        );

        expect(result.referenceTime, refTime);
      });

      test('preserves data length', () {
        final data = List.generate(
          10,
          (i) => ForecastPoint(
            validTime: DateTime.utc(2025, 6, 15, i),
            flow: 50.0 + i,
          ),
        );

        final result = ForecastSeries.withPreferredUnits(
          originalUnits: 'CMS',
          preferredUnits: 'CFS',
          originalData: data,
        );

        expect(result.data.length, 10);
      });

      test('preserves validTime for each point', () {
        final data = [
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 12), flow: 100.0),
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 13), flow: 200.0),
        ];

        final result = ForecastSeries.withPreferredUnits(
          originalUnits: 'CMS',
          preferredUnits: 'CFS',
          originalData: data,
        );

        expect(result.data[0].validTime, DateTime.utc(2025, 6, 15, 12));
        expect(result.data[1].validTime, DateTime.utc(2025, 6, 15, 13));
      });
    });
  });

  group('ReachData — flood classification', () {
    // Return periods are stored in CMS in the real data.
    // Use simple CMS values for predictable threshold conversion.
    late ReachData reachWithPeriods;

    setUp(() {
      reachWithPeriods = createTestReachData(
        returnPeriods: {
          2: 100.0,   // 2yr threshold: 100 CMS
          5: 200.0,   // 5yr threshold: 200 CMS
          10: 300.0,  // 10yr threshold: 300 CMS
          25: 400.0,  // 25yr threshold: 400 CMS
        },
      );
    });

    group('isCacheStale', () {
      test('returns false when cache is fresh', () {
        final reach = createTestReachData(cachedAt: DateTime.now());
        expect(reach.isCacheStale(), false);
      });

      test('returns true when cache exceeds 180 days', () {
        final reach = createTestReachData(
          cachedAt: DateTime.now().subtract(const Duration(days: 200)),
        );
        expect(reach.isCacheStale(), true);
      });

      test('returns false when cache is within 180 days', () {
        final reach = createTestReachData(
          cachedAt: DateTime.now().subtract(const Duration(days: 179)),
        );
        expect(reach.isCacheStale(), false);
      });

      test('respects custom maxAge', () {
        final reach = createTestReachData(
          cachedAt: DateTime.now().subtract(const Duration(hours: 5)),
        );
        // Fresh for default 180 days, but stale for a 1-hour maxAge
        expect(reach.isCacheStale(), false);
        expect(reach.isCacheStale(maxAge: const Duration(hours: 1)), true);
      });
    });

    group('getReturnPeriodsInUnit', () {
      test('returns null when returnPeriods is null', () {
        final reach = createTestReachData(returnPeriods: null);
        expect(reach.getReturnPeriodsInUnit('CFS'), isNull);
      });

      test('returns CMS values when target is CMS', () {
        final periods = reachWithPeriods.getReturnPeriodsInUnit('CMS');
        expect(periods, isNotNull);
        // CMS -> CMS = no conversion, values should be the same
        expect(periods![2], closeTo(100.0, 0.01));
        expect(periods[5], closeTo(200.0, 0.01));
        expect(periods[10], closeTo(300.0, 0.01));
        expect(periods[25], closeTo(400.0, 0.01));
      });

      test('converts to CFS correctly', () {
        final periods = reachWithPeriods.getReturnPeriodsInUnit('CFS');
        expect(periods, isNotNull);
        // 100 CMS * 35.3147 = ~3531.47 CFS
        expect(periods![2], closeTo(3531.47, 1.0));
        expect(periods[5], closeTo(7062.94, 1.0));
        expect(periods[10], closeTo(10594.41, 1.0));
        expect(periods[25], closeTo(14125.88, 1.0));
      });

      test('includes all 4 threshold years', () {
        final periods = reachWithPeriods.getReturnPeriodsInUnit('CFS');
        expect(periods!.keys, containsAll([2, 5, 10, 25]));
      });
    });

    group('getFlowCategory', () {
      test('returns Unknown when no return periods', () {
        final reach = createTestReachData(returnPeriods: null);
        expect(reach.getFlowCategory(100.0, 'CMS'), 'Unknown');
      });

      test('returns Normal when flow < 2yr threshold', () {
        // 2yr threshold = 100 CMS, flow = 50 CMS
        expect(reachWithPeriods.getFlowCategory(50.0, 'CMS'), 'Normal');
      });

      test('returns Action when flow between 2yr and 5yr thresholds', () {
        // 2yr = 100, 5yr = 200, flow = 150 CMS
        expect(reachWithPeriods.getFlowCategory(150.0, 'CMS'), 'Action');
      });

      test('returns Moderate when flow between 5yr and 10yr thresholds', () {
        // 5yr = 200, 10yr = 300, flow = 250 CMS
        expect(reachWithPeriods.getFlowCategory(250.0, 'CMS'), 'Moderate');
      });

      test('returns Major when flow between 10yr and 25yr thresholds', () {
        // 10yr = 300, 25yr = 400, flow = 350 CMS
        expect(reachWithPeriods.getFlowCategory(350.0, 'CMS'), 'Major');
      });

      test('returns Extreme when flow > 25yr threshold', () {
        // 25yr = 400, flow = 500 CMS
        expect(reachWithPeriods.getFlowCategory(500.0, 'CMS'), 'Extreme');
      });

      test('works with CFS flow values (converts thresholds)', () {
        // 2yr threshold in CFS: 100 * 35.3147 = ~3531.47
        // Flow of 1000 CFS should be Normal (well below 2yr CFS threshold)
        expect(reachWithPeriods.getFlowCategory(1000.0, 'CFS'), 'Normal');

        // Flow of 5000 CFS (between 2yr=3531 and 5yr=7063) should be Action
        expect(reachWithPeriods.getFlowCategory(5000.0, 'CFS'), 'Action');

        // Flow of 15000 CFS (above 25yr=14126) should be Extreme
        expect(reachWithPeriods.getFlowCategory(15000.0, 'CFS'), 'Extreme');
      });

      test('boundary: flow exactly at 2yr threshold', () {
        // At exactly the threshold, flow is NOT < threshold, so it should be Action
        expect(reachWithPeriods.getFlowCategory(100.0, 'CMS'), 'Action');
      });

      test('boundary: flow at zero', () {
        expect(reachWithPeriods.getFlowCategory(0.0, 'CMS'), 'Normal');
      });
    });

    group('getNextThreshold', () {
      test('returns null when no return periods', () {
        final reach = createTestReachData(returnPeriods: null);
        expect(reach.getNextThreshold(100.0), isNull);
      });

      test('returns lowest threshold above given flow', () {
        // getNextThreshold takes CFS and converts to CMS internally
        // CFS flow = 0 -> CMS flow ≈ 0, next threshold should be 2yr (100 CMS)
        final next = reachWithPeriods.getNextThreshold(0.0);
        expect(next, isNotNull);
        expect(next!.key, 2);
        expect(next.value, 100.0);
      });

      test('returns null when flow exceeds all thresholds', () {
        // Very high CFS flow that converts to > 400 CMS
        // 400 CMS = ~14126 CFS, so use 15000 CFS
        final next = reachWithPeriods.getNextThreshold(15000.0);
        expect(next, isNull);
      });
    });
  });
}
