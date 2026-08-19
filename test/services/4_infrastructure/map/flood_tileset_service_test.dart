import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/4_infrastructure/map/flood_tileset_service.dart';

void main() {
  group('FloodTilesetService.idForDate', () {
    test('formats a normal date', () {
      expect(
        FloodTilesetService.idForDate(DateTime.utc(2026, 8, 19)),
        'byu-hydroinformatics.rivr-flooded-20260819',
      );
    });

    test('zero-pads single-digit months and days', () {
      expect(
        FloodTilesetService.idForDate(DateTime.utc(2026, 1, 5)),
        'byu-hydroinformatics.rivr-flooded-20260105',
      );
    });

    // The id is a date stamp, so it has to keep working past this year, past a
    // leap day, and across a year boundary — the cases a naive implementation
    // gets wrong long after anyone is watching.
    test('works for future years', () {
      expect(
        FloodTilesetService.idForDate(DateTime.utc(2027, 12, 31)),
        'byu-hydroinformatics.rivr-flooded-20271231',
      );
      expect(
        FloodTilesetService.idForDate(DateTime.utc(2030, 6, 7)),
        'byu-hydroinformatics.rivr-flooded-20300607',
      );
      expect(
        FloodTilesetService.idForDate(DateTime.utc(2099, 11, 30)),
        'byu-hydroinformatics.rivr-flooded-20991130',
      );
    });

    test('handles leap day', () {
      expect(
        FloodTilesetService.idForDate(DateTime.utc(2028, 2, 29)),
        'byu-hydroinformatics.rivr-flooded-20280229',
      );
    });

    test('converts local time to UTC before stamping', () {
      // The build job stamps in UTC. A device just past midnight local but
      // still on the previous UTC day must ask for the UTC day, or it requests
      // a tileset that does not exist yet.
      final local = DateTime.utc(2026, 8, 19, 2).toLocal();
      expect(
        FloodTilesetService.idForDate(local),
        'byu-hydroinformatics.rivr-flooded-20260819',
      );
    });
  });

  group('FloodTilesetService.fallbackIds', () {
    test('returns the retention window, newest first', () {
      final ids = FloodTilesetService.fallbackIds(from: DateTime.utc(2026, 8, 19));
      expect(ids, [
        'byu-hydroinformatics.rivr-flooded-20260819',
        'byu-hydroinformatics.rivr-flooded-20260818',
        'byu-hydroinformatics.rivr-flooded-20260817',
      ]);
    });

    test('steps back across a month boundary', () {
      final ids = FloodTilesetService.fallbackIds(from: DateTime.utc(2026, 3, 1));
      expect(ids, [
        'byu-hydroinformatics.rivr-flooded-20260301',
        'byu-hydroinformatics.rivr-flooded-20260228',
        'byu-hydroinformatics.rivr-flooded-20260227',
      ]);
    });

    test('steps back across a year boundary', () {
      final ids = FloodTilesetService.fallbackIds(from: DateTime.utc(2027, 1, 1));
      expect(ids, [
        'byu-hydroinformatics.rivr-flooded-20270101',
        'byu-hydroinformatics.rivr-flooded-20261231',
        'byu-hydroinformatics.rivr-flooded-20261230',
      ]);
    });

    test('steps back across a leap-year February', () {
      final ids = FloodTilesetService.fallbackIds(from: DateTime.utc(2028, 3, 1));
      expect(ids, [
        'byu-hydroinformatics.rivr-flooded-20280301',
        'byu-hydroinformatics.rivr-flooded-20280229',
        'byu-hydroinformatics.rivr-flooded-20280228',
      ]);
    });

    test('never returns more than the retention window', () {
      expect(
        FloodTilesetService.fallbackIds(from: DateTime.utc(2026, 8, 19)).length,
        FloodTilesetService.fallbackDays,
      );
    });
  });
}
