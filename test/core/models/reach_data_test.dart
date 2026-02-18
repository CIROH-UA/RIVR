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
  });
}
