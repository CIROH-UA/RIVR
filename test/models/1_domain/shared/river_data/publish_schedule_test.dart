// test/models/1_domain/shared/river_data/publish_schedule_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/river_data/publish_schedule.dart';

void main() {
  group('PublishSchedule.nextTopOfHour', () {
    test('mid-hour rounds up to the next hour', () {
      expect(
        PublishSchedule.nextTopOfHour(DateTime.utc(2026, 7, 10, 12, 30)),
        DateTime.utc(2026, 7, 10, 13, 0),
      );
    });

    test('exactly on the hour advances to the following hour', () {
      expect(
        PublishSchedule.nextTopOfHour(DateTime.utc(2026, 7, 10, 12, 0)),
        DateTime.utc(2026, 7, 10, 13, 0),
      );
    });

    test('rolls to next day at 23:xx', () {
      expect(
        PublishSchedule.nextTopOfHour(DateTime.utc(2026, 7, 10, 23, 15)),
        DateTime.utc(2026, 7, 11, 0, 0),
      );
    });

    test('normalizes a non-UTC now', () {
      // 08:30-04:00 == 12:30Z -> 13:00Z
      expect(
        PublishSchedule.nextTopOfHour(
          DateTime.parse('2026-07-10T08:30:00-04:00'),
        ),
        DateTime.utc(2026, 7, 10, 13, 0),
      );
    });
  });

  group('PublishSchedule.nextCycle (every 6h)', () {
    test('mid-cycle rounds up to the next boundary', () {
      expect(
        PublishSchedule.nextCycle(DateTime.utc(2026, 7, 10, 13, 10),
            everyHours: 6),
        DateTime.utc(2026, 7, 10, 18, 0),
      );
    });

    test('exactly on a boundary advances to the next', () {
      expect(
        PublishSchedule.nextCycle(DateTime.utc(2026, 7, 10, 18, 0),
            everyHours: 6),
        DateTime.utc(2026, 7, 11, 0, 0),
      );
    });

    test('early morning goes to 06:00Z', () {
      expect(
        PublishSchedule.nextCycle(DateTime.utc(2026, 7, 10, 2, 45),
            everyHours: 6),
        DateTime.utc(2026, 7, 10, 6, 0),
      );
    });
  });

  group('PublishSchedule.nextUtcMidnight', () {
    test('any time of day -> next 00:00Z', () {
      expect(
        PublishSchedule.nextUtcMidnight(DateTime.utc(2026, 7, 10, 15, 20)),
        DateTime.utc(2026, 7, 11, 0, 0),
      );
    });

    test('exactly midnight advances a full day', () {
      expect(
        PublishSchedule.nextUtcMidnight(DateTime.utc(2026, 7, 10, 0, 0)),
        DateTime.utc(2026, 7, 11, 0, 0),
      );
    });

    test('late-UTC local time still lands on the correct UTC day', () {
      // 20:00-06:00 == 02:00Z on the 11th -> next midnight is the 12th
      expect(
        PublishSchedule.nextUtcMidnight(
          DateTime.parse('2026-07-10T20:00:00-06:00'),
        ),
        DateTime.utc(2026, 7, 12, 0, 0),
      );
    });
  });
}
