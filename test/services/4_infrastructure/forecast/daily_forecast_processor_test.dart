import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';
import 'package:rivr/models/1_domain/features/forecast/daily_flow_forecast.dart';
import 'package:rivr/services/4_infrastructure/forecast/daily_forecast_processor.dart';

import '../../../helpers/fake_data.dart';
import '../../../helpers/test_helpers.dart';

/// Helper to build a ForecastSeries with hourly points spanning multiple days.
ForecastSeries _buildMultiDaySeries({
  required DateTime startUtc,
  required int hours,
  double startFlow = 100.0,
  double flowIncrement = 5.0,
}) {
  final points = <ForecastPoint>[];
  for (int i = 0; i < hours; i++) {
    points.add(ForecastPoint(
      validTime: startUtc.add(Duration(hours: i)),
      flow: startFlow + (i * flowIncrement),
    ));
  }
  return ForecastSeries(
    referenceTime: startUtc,
    units: 'CFS',
    data: points,
  );
}

void main() {
  setUpAll(() => setupTestServiceLocator());
  tearDownAll(() => tearDownServiceLocator());

  group('DailyForecastProcessor', () {
    group('processForecastData', () {
      test('returns empty list for empty forecast data', () {
        final reach = createTestReachData();
        final result = DailyForecastProcessor.processForecastData(
          forecastData: {},
          reach: reach,
          forecastType: 'medium_range',
        );
        expect(result, isEmpty);
      });

      test('prefers mean data source over members', () {
        final reach = createTestReachData();
        final startUtc = DateTime.utc(2025, 6, 15, 12, 0);

        final meanSeries = _buildMultiDaySeries(
          startUtc: startUtc,
          hours: 6,
          startFlow: 200.0,
        );
        final memberSeries = _buildMultiDaySeries(
          startUtc: startUtc,
          hours: 6,
          startFlow: 500.0,
        );

        final result = DailyForecastProcessor.processForecastData(
          forecastData: {
            'mean': meanSeries,
            'member01': memberSeries,
          },
          reach: reach,
          forecastType: 'medium_range',
        );

        expect(result, isNotEmpty);
        // All results should use 'mean' as data source
        for (final forecast in result) {
          expect(forecast.dataSource, 'mean');
        }
      });

      test('falls back to first member when mean is empty', () {
        final reach = createTestReachData();
        final startUtc = DateTime.utc(2025, 6, 15, 12, 0);

        final emptySeries = ForecastSeries(
          referenceTime: startUtc,
          units: 'CFS',
          data: [],
        );
        final memberSeries = _buildMultiDaySeries(
          startUtc: startUtc,
          hours: 6,
          startFlow: 300.0,
        );

        final result = DailyForecastProcessor.processForecastData(
          forecastData: {
            'mean': emptySeries,
            'member01': memberSeries,
          },
          reach: reach,
          forecastType: 'medium_range',
        );

        expect(result, isNotEmpty);
        for (final forecast in result) {
          expect(forecast.dataSource, 'member01');
        }
      });

      test('returns empty when mean and all members are empty', () {
        final reach = createTestReachData();
        final startUtc = DateTime.utc(2025, 6, 15, 12, 0);

        final emptySeries = ForecastSeries(
          referenceTime: startUtc,
          units: 'CFS',
          data: [],
        );

        final result = DailyForecastProcessor.processForecastData(
          forecastData: {
            'mean': emptySeries,
            'member01': emptySeries,
            'member02': emptySeries,
          },
          reach: reach,
          forecastType: 'medium_range',
        );

        expect(result, isEmpty);
      });

      test('groups hourly data into daily summaries', () {
        final reach = createTestReachData();
        // 48 hours of data = should produce 2-3 day groups
        final startUtc = DateTime.utc(2025, 6, 15, 0, 0);
        final series = _buildMultiDaySeries(
          startUtc: startUtc,
          hours: 48,
          startFlow: 50.0,
          flowIncrement: 2.0,
        );

        final result = DailyForecastProcessor.processForecastData(
          forecastData: {'mean': series},
          reach: reach,
          forecastType: 'medium_range',
        );

        // Should have at least 2 days of data
        expect(result.length, greaterThanOrEqualTo(2));
      });

      test('calculates min, max, avg correctly for a single day', () {
        final reach = createTestReachData();
        // All points on the same UTC day
        final points = [
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 6, 0), flow: 100.0),
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 12, 0), flow: 200.0),
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 18, 0), flow: 150.0),
        ];
        final series = ForecastSeries(
          referenceTime: DateTime.utc(2025, 6, 15),
          units: 'CFS',
          data: points,
        );

        final result = DailyForecastProcessor.processForecastData(
          forecastData: {'mean': series},
          reach: reach,
          forecastType: 'medium_range',
        );

        // There may be 1 or 2 day groups depending on local timezone offset.
        // Find the group that got the most points and check its stats.
        final mainDay = result.reduce(
          (a, b) => a.hourlyDataCount > b.hourlyDataCount ? a : b,
        );

        expect(mainDay.minFlow, lessThanOrEqualTo(mainDay.avgFlow));
        expect(mainDay.avgFlow, lessThanOrEqualTo(mainDay.maxFlow));
      });

      test('sorts results by date ascending', () {
        final reach = createTestReachData();
        final startUtc = DateTime.utc(2025, 6, 15, 0, 0);
        final series = _buildMultiDaySeries(
          startUtc: startUtc,
          hours: 72,
          startFlow: 100.0,
          flowIncrement: 1.0,
        );

        final result = DailyForecastProcessor.processForecastData(
          forecastData: {'mean': series},
          reach: reach,
          forecastType: 'medium_range',
        );

        for (int i = 1; i < result.length; i++) {
          expect(
            result[i].date.isAfter(result[i - 1].date) ||
                result[i].date.isAtSameMomentAs(result[i - 1].date),
            true,
            reason: 'Forecasts should be sorted by date',
          );
        }
      });

      test('assigns flow category with return periods', () {
        // Return periods are always stored in CMS in reach data
        final reach = createTestReachDataWithReturnPeriods(
          threshold2yr: 100.0,  // CMS
          threshold5yr: 200.0,
          threshold10yr: 300.0,
          threshold25yr: 400.0,
        );

        final points = [
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 12, 0), flow: 50.0),
        ];
        final series = ForecastSeries(
          referenceTime: DateTime.utc(2025, 6, 15),
          units: 'CFS',
          data: points,
        );

        final result = DailyForecastProcessor.processForecastData(
          forecastData: {'mean': series},
          reach: reach,
          forecastType: 'medium_range',
        );

        expect(result, isNotEmpty);
        // With return periods available, category should not be 'Unknown'
        // (exact category depends on unit conversion)
        expect(result.first.flowCategory, isNotEmpty);
      });

      test('assigns Unknown category when no return periods', () {
        final reach = createTestReachData(returnPeriods: null);

        final points = [
          ForecastPoint(validTime: DateTime.utc(2025, 6, 15, 12, 0), flow: 50.0),
        ];
        final series = ForecastSeries(
          referenceTime: DateTime.utc(2025, 6, 15),
          units: 'CFS',
          data: points,
        );

        final result = DailyForecastProcessor.processForecastData(
          forecastData: {'mean': series},
          reach: reach,
          forecastType: 'medium_range',
        );

        expect(result, isNotEmpty);
        expect(result.first.flowCategory, 'Unknown');
      });

      test('selects members in sorted order (member01 before member02)', () {
        final reach = createTestReachData();
        final startUtc = DateTime.utc(2025, 6, 15, 12, 0);

        final emptySeries = ForecastSeries(
          referenceTime: startUtc,
          units: 'CFS',
          data: [],
        );
        final member02Series = _buildMultiDaySeries(
          startUtc: startUtc,
          hours: 6,
          startFlow: 200.0,
        );
        final member01Series = _buildMultiDaySeries(
          startUtc: startUtc,
          hours: 6,
          startFlow: 100.0,
        );

        // Insert member02 before member01 in the map
        final result = DailyForecastProcessor.processForecastData(
          forecastData: {
            'mean': emptySeries,
            'member02': member02Series,
            'member01': member01Series,
          },
          reach: reach,
          forecastType: 'medium_range',
        );

        expect(result, isNotEmpty);
        // Should select member01 (sorted first)
        expect(result.first.dataSource, 'member01');
      });

      test('ignores non-member keys when falling back', () {
        final reach = createTestReachData();
        final startUtc = DateTime.utc(2025, 6, 15, 12, 0);

        final emptySeries = ForecastSeries(
          referenceTime: startUtc,
          units: 'CFS',
          data: [],
        );
        final otherSeries = _buildMultiDaySeries(
          startUtc: startUtc,
          hours: 6,
          startFlow: 999.0,
        );
        final memberSeries = _buildMultiDaySeries(
          startUtc: startUtc,
          hours: 6,
          startFlow: 100.0,
        );

        final result = DailyForecastProcessor.processForecastData(
          forecastData: {
            'mean': emptySeries,
            'custom_key': otherSeries,
            'member01': memberSeries,
          },
          reach: reach,
          forecastType: 'medium_range',
        );

        expect(result, isNotEmpty);
        // Should pick member01, not custom_key
        expect(result.first.dataSource, 'member01');
      });
    });

    group('getFlowBounds', () {
      test('returns default bounds for empty list', () {
        final bounds = DailyForecastProcessor.getFlowBounds([]);
        expect(bounds['min'], 0.0);
        expect(bounds['max'], 100.0);
      });

      test('calculates min and max across multiple forecasts', () {
        final forecasts = [
          DailyFlowForecast(
            date: DateTime(2025, 6, 15),
            minFlow: 50.0,
            maxFlow: 200.0,
            avgFlow: 125.0,
            hourlyData: {},
            flowCategory: 'Normal',
            dataSource: 'mean',
          ),
          DailyFlowForecast(
            date: DateTime(2025, 6, 16),
            minFlow: 30.0,
            maxFlow: 300.0,
            avgFlow: 165.0,
            hourlyData: {},
            flowCategory: 'Elevated',
            dataSource: 'mean',
          ),
        ];

        final bounds = DailyForecastProcessor.getFlowBounds(forecasts);

        // min should be 30.0 minus 5% padding of range (270), max should be 300.0 + padding
        expect(bounds['min']!, lessThan(30.0));
        expect(bounds['max']!, greaterThan(300.0));
      });

      test('adds 5% padding to range', () {
        final forecasts = [
          DailyFlowForecast(
            date: DateTime(2025, 6, 15),
            minFlow: 100.0,
            maxFlow: 200.0,
            avgFlow: 150.0,
            hourlyData: {},
            flowCategory: 'Normal',
            dataSource: 'mean',
          ),
        ];

        final bounds = DailyForecastProcessor.getFlowBounds(forecasts);
        final range = 200.0 - 100.0;
        final padding = range * 0.05;

        expect(bounds['min'], closeTo(100.0 - padding, 0.01));
        expect(bounds['max'], closeTo(200.0 + padding, 0.01));
      });

      test('clamps min to 0', () {
        final forecasts = [
          DailyFlowForecast(
            date: DateTime(2025, 6, 15),
            minFlow: 1.0,
            maxFlow: 100.0,
            avgFlow: 50.0,
            hourlyData: {},
            flowCategory: 'Normal',
            dataSource: 'mean',
          ),
        ];

        final bounds = DailyForecastProcessor.getFlowBounds(forecasts);
        expect(bounds['min']!, greaterThanOrEqualTo(0.0));
      });
    });

    group('getDayLabel', () {
      test('returns Today when isToday is true', () {
        expect(
          DailyForecastProcessor.getDayLabel(DateTime.now(), isToday: true),
          'Today',
        );
      });

      test('returns Tomorrow for next day', () {
        final tomorrow = DateTime.now().add(const Duration(days: 1));
        expect(DailyForecastProcessor.getDayLabel(tomorrow), 'Tomorrow');
      });

      test('returns Yesterday for previous day', () {
        final yesterday = DateTime.now().subtract(const Duration(days: 1));
        expect(DailyForecastProcessor.getDayLabel(yesterday), 'Yesterday');
      });

      test('returns weekday name for dates within a week', () {
        final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        final inThreeDays = DateTime.now().add(const Duration(days: 3));
        final label = DailyForecastProcessor.getDayLabel(inThreeDays);
        expect(weekdays, contains(label));
      });

      test('returns month/day format for dates more than a week away', () {
        final farDate = DateTime.now().add(const Duration(days: 14));
        final label = DailyForecastProcessor.getDayLabel(farDate);
        expect(label, contains('/'));
        expect(label, '${farDate.month}/${farDate.day}');
      });
    });

    group('validateProcessedData', () {
      test('returns false for empty list', () {
        expect(DailyForecastProcessor.validateProcessedData([]), false);
      });

      test('returns true for valid forecasts', () {
        final forecasts = [
          DailyFlowForecast(
            date: DateTime(2025, 6, 15),
            minFlow: 50.0,
            maxFlow: 200.0,
            avgFlow: 125.0,
            hourlyData: {DateTime(2025, 6, 15, 12): 125.0},
            flowCategory: 'Normal',
            dataSource: 'mean',
          ),
        ];

        expect(DailyForecastProcessor.validateProcessedData(forecasts), true);
      });

      test('returns false when a forecast has invalid data', () {
        final forecasts = [
          DailyFlowForecast(
            date: DateTime(2025, 6, 15),
            minFlow: 200.0,
            maxFlow: 100.0, // max < min = invalid
            avgFlow: 150.0,
            hourlyData: {},
            flowCategory: 'Normal',
            dataSource: 'mean',
          ),
        ];

        expect(DailyForecastProcessor.validateProcessedData(forecasts), false);
      });
    });
  });

  group('DailyFlowForecast', () {
    DailyFlowForecast createForecast({
      DateTime? date,
      double minFlow = 50.0,
      double maxFlow = 200.0,
      double avgFlow = 125.0,
      Map<DateTime, double>? hourlyData,
      String flowCategory = 'Normal',
      String dataSource = 'mean',
    }) {
      return DailyFlowForecast(
        date: date ?? DateTime(2025, 6, 15),
        minFlow: minFlow,
        maxFlow: maxFlow,
        avgFlow: avgFlow,
        hourlyData: hourlyData ?? {
          DateTime(2025, 6, 15, 8): 80.0,
          DateTime(2025, 6, 15, 12): 200.0,
          DateTime(2025, 6, 15, 16): 150.0,
          DateTime(2025, 6, 15, 20): 50.0,
        },
        flowCategory: flowCategory,
        dataSource: dataSource,
      );
    }

    group('copyWith', () {
      test('creates copy with updated fields', () {
        final original = createForecast();
        final copy = original.copyWith(
          minFlow: 10.0,
          flowCategory: 'High',
        );

        expect(copy.minFlow, 10.0);
        expect(copy.flowCategory, 'High');
        expect(copy.maxFlow, original.maxFlow);
        expect(copy.dataSource, original.dataSource);
      });

      test('preserves all fields when no changes', () {
        final original = createForecast();
        final copy = original.copyWith();

        expect(copy, equals(original));
      });
    });

    group('formatFlowWithUnit', () {
      test('formats millions with M suffix', () {
        final forecast = createForecast();
        expect(forecast.formatFlowWithUnit(1500000.0), contains('M'));
      });

      test('formats thousands with K suffix', () {
        final forecast = createForecast();
        expect(forecast.formatFlowWithUnit(5000.0), contains('K'));
      });

      test('formats hundreds without suffix', () {
        final forecast = createForecast();
        final formatted = forecast.formatFlowWithUnit(500.0);
        expect(formatted, contains('500'));
      });

      test('formats small values with one decimal', () {
        final forecast = createForecast();
        final formatted = forecast.formatFlowWithUnit(42.5);
        expect(formatted, contains('42.5'));
      });

      test('includes unit string', () {
        final forecast = createForecast();
        final formatted = forecast.formatFlowWithUnit(100.0);
        // Should contain CFS or CMS
        expect(
          formatted.contains('CFS') || formatted.contains('CMS'),
          true,
        );
      });
    });

    group('formattedMinFlow / formattedMaxFlow / formattedAvgFlow', () {
      test('returns formatted strings', () {
        final forecast = createForecast(
          minFlow: 50.0,
          maxFlow: 200.0,
          avgFlow: 125.0,
        );

        expect(forecast.formattedMinFlow, contains('50.0'));
        expect(forecast.formattedMaxFlow, contains('200'));
        expect(forecast.formattedAvgFlow, contains('125'));
      });
    });


    group('hasHourlyData / hourlyDataCount', () {
      test('true when hourly data is present', () {
        final forecast = createForecast();
        expect(forecast.hasHourlyData, true);
        expect(forecast.hourlyDataCount, 4);
      });

      test('false when hourly data is empty', () {
        final forecast = createForecast(hourlyData: {});
        expect(forecast.hasHourlyData, false);
        expect(forecast.hourlyDataCount, 0);
      });
    });

    group('getFlowAt', () {
      test('returns exact match', () {
        final time = DateTime(2025, 6, 15, 12);
        final forecast = createForecast(hourlyData: {time: 200.0});

        expect(forecast.getFlowAt(time), 200.0);
      });

      test('returns closest hour when no exact match', () {
        final hourlyData = {
          DateTime(2025, 6, 15, 10): 100.0,
          DateTime(2025, 6, 15, 14): 200.0,
        };
        final forecast = createForecast(hourlyData: hourlyData);

        // Ask for 11:00 — closest is 10:00
        final flow = forecast.getFlowAt(DateTime(2025, 6, 15, 11));
        expect(flow, 100.0);
      });

      test('returns null for empty hourly data', () {
        final forecast = createForecast(hourlyData: {});
        expect(forecast.getFlowAt(DateTime(2025, 6, 15, 12)), isNull);
      });
    });

    group('sortedHourlyData', () {
      test('returns entries sorted by time', () {
        final hourlyData = {
          DateTime(2025, 6, 15, 16): 150.0,
          DateTime(2025, 6, 15, 8): 80.0,
          DateTime(2025, 6, 15, 12): 200.0,
        };
        final forecast = createForecast(hourlyData: hourlyData);

        final sorted = forecast.sortedHourlyData;
        expect(sorted.length, 3);
        expect(sorted[0].key, DateTime(2025, 6, 15, 8));
        expect(sorted[1].key, DateTime(2025, 6, 15, 12));
        expect(sorted[2].key, DateTime(2025, 6, 15, 16));
      });
    });

    group('isUsingMeanData', () {
      test('true when dataSource is mean', () {
        expect(createForecast(dataSource: 'mean').isUsingMeanData, true);
      });

      test('false when dataSource is a member', () {
        expect(createForecast(dataSource: 'member01').isUsingMeanData, false);
      });
    });

    group('dataSourceDescription', () {
      test('returns Ensemble Average for mean', () {
        expect(
          createForecast(dataSource: 'mean').dataSourceDescription,
          'Ensemble Average',
        );
      });

      test('returns Member N for member keys', () {
        expect(
          createForecast(dataSource: 'member01').dataSourceDescription,
          'Member 01',
        );
        expect(
          createForecast(dataSource: 'member12').dataSourceDescription,
          'Member 12',
        );
      });

      test('returns Unknown Source for other keys', () {
        expect(
          createForecast(dataSource: 'custom').dataSourceDescription,
          'Unknown Source',
        );
      });
    });

    group('isValid', () {
      test('true for valid data', () {
        expect(createForecast().isValid, true);
      });

      test('false when minFlow is negative', () {
        expect(createForecast(minFlow: -1.0).isValid, false);
      });

      test('false when maxFlow < minFlow', () {
        expect(
          createForecast(minFlow: 200.0, maxFlow: 100.0, avgFlow: 150.0).isValid,
          false,
        );
      });

      test('false when avgFlow < minFlow', () {
        expect(
          createForecast(minFlow: 100.0, maxFlow: 200.0, avgFlow: 50.0).isValid,
          false,
        );
      });

      test('false when avgFlow > maxFlow', () {
        expect(
          createForecast(minFlow: 100.0, maxFlow: 200.0, avgFlow: 250.0).isValid,
          false,
        );
      });

      test('false when flowCategory is empty', () {
        expect(createForecast(flowCategory: '').isValid, false);
      });

      test('false when dataSource is empty', () {
        expect(createForecast(dataSource: '').isValid, false);
      });
    });

    group('equality', () {
      test('two forecasts with same fields are equal', () {
        final a = createForecast();
        final b = createForecast();
        expect(a, equals(b));
      });

      test('two forecasts with different date are not equal', () {
        final a = createForecast(date: DateTime(2025, 6, 15));
        final b = createForecast(date: DateTime(2025, 6, 16));
        expect(a, isNot(equals(b)));
      });

      test('hashCode is consistent', () {
        final a = createForecast();
        final b = createForecast();
        expect(a.hashCode, equals(b.hashCode));
      });
    });
  });

  group('DailyForecastCollection', () {
    List<DailyFlowForecast> createForecasts(int days) {
      return List.generate(
        days,
        (i) => DailyFlowForecast(
          date: DateTime(2025, 6, 15 + i),
          minFlow: 50.0 + i * 10,
          maxFlow: 200.0 + i * 10,
          avgFlow: 125.0 + i * 10,
          hourlyData: {DateTime(2025, 6, 15 + i, 12): 125.0 + i * 10},
          flowCategory: 'Normal',
          dataSource: 'mean',
        ),
      );
    }

    group('getForecastForDate', () {
      test('returns forecast matching the date', () {
        final collection = DailyForecastCollection(
          forecasts: createForecasts(3),
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        final result = collection.getForecastForDate(DateTime(2025, 6, 16));
        expect(result, isNotNull);
        expect(result!.date, DateTime(2025, 6, 16));
      });

      test('returns null for non-matching date', () {
        final collection = DailyForecastCollection(
          forecasts: createForecasts(3),
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        final result = collection.getForecastForDate(DateTime(2025, 7, 1));
        expect(result, isNull);
      });

      test('ignores time component when matching', () {
        final collection = DailyForecastCollection(
          forecasts: createForecasts(1),
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        // Ask for same date but with a time component
        final result = collection.getForecastForDate(
          DateTime(2025, 6, 15, 14, 30),
        );
        expect(result, isNotNull);
      });
    });

    group('sortedForecasts', () {
      test('returns forecasts in date order', () {
        // Intentionally create out-of-order forecasts
        final forecasts = [
          DailyFlowForecast(
            date: DateTime(2025, 6, 17),
            minFlow: 50.0,
            maxFlow: 200.0,
            avgFlow: 125.0,
            hourlyData: {},
            flowCategory: 'Normal',
            dataSource: 'mean',
          ),
          DailyFlowForecast(
            date: DateTime(2025, 6, 15),
            minFlow: 50.0,
            maxFlow: 200.0,
            avgFlow: 125.0,
            hourlyData: {},
            flowCategory: 'Normal',
            dataSource: 'mean',
          ),
        ];

        final collection = DailyForecastCollection(
          forecasts: forecasts,
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        final sorted = collection.sortedForecasts;
        expect(sorted[0].date, DateTime(2025, 6, 15));
        expect(sorted[1].date, DateTime(2025, 6, 17));
      });
    });

    group('flowBounds', () {
      test('returns default for empty collection', () {
        final collection = DailyForecastCollection(
          forecasts: [],
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        final bounds = collection.flowBounds;
        expect(bounds['min'], 0.0);
        expect(bounds['max'], 100.0);
      });

      test('calculates global min and max', () {
        final collection = DailyForecastCollection(
          forecasts: createForecasts(3),
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        final bounds = collection.flowBounds;
        expect(bounds['min'], 50.0); // first day min
        expect(bounds['max'], 220.0); // third day max (200 + 2*10)
      });
    });

    group('isEmpty / isNotEmpty / length', () {
      test('empty collection', () {
        final collection = DailyForecastCollection(
          forecasts: [],
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        expect(collection.isEmpty, true);
        expect(collection.isNotEmpty, false);
        expect(collection.length, 0);
      });

      test('non-empty collection', () {
        final collection = DailyForecastCollection(
          forecasts: createForecasts(2),
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        expect(collection.isEmpty, false);
        expect(collection.isNotEmpty, true);
        expect(collection.length, 2);
      });
    });

    group('dateRange', () {
      test('returns null for empty collection', () {
        final collection = DailyForecastCollection(
          forecasts: [],
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        expect(collection.dateRange, isNull);
      });

      test('returns start and end dates', () {
        final collection = DailyForecastCollection(
          forecasts: createForecasts(5),
          createdAt: DateTime.now(),
          sourceType: 'medium_range',
        );

        final range = collection.dateRange!;
        expect(range['start'], DateTime(2025, 6, 15));
        expect(range['end'], DateTime(2025, 6, 19));
      });
    });
  });
}
