// test/models/1_domain/shared/river_data/freshness_window_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';

void main() {
  group('FreshnessWindow', () {
    final fetchedAt = DateTime.utc(2026, 7, 10, 12, 0);
    final validUntil = DateTime.utc(2026, 7, 10, 13, 0); // next hourly publish
    final window = FreshnessWindow(
      fetchedAt: fetchedAt,
      validUntil: validUntil,
    );

    test('is fresh before validUntil', () {
      expect(window.isFreshAt(DateTime.utc(2026, 7, 10, 12, 30)), isTrue);
      expect(window.isStaleAt(DateTime.utc(2026, 7, 10, 12, 30)), isFalse);
    });

    test('is stale at/after validUntil', () {
      expect(window.isFreshAt(validUntil), isFalse);
      expect(window.isStaleAt(DateTime.utc(2026, 7, 10, 13, 1)), isTrue);
    });

    test('compares in UTC regardless of the now zone offset', () {
      // 12:30 UTC expressed as a +02:00 local time is 14:30 — still before 13:00Z.
      final localNow = DateTime.parse('2026-07-10T14:30:00+02:00');
      expect(window.isFreshAt(localNow), isTrue);
    });

    test('normalizes constructor inputs to UTC', () {
      final local = FreshnessWindow(
        fetchedAt: DateTime.parse('2026-07-10T08:00:00-04:00'),
        validUntil: DateTime.parse('2026-07-10T09:00:00-04:00'),
      );
      expect(local.fetchedAt.isUtc, isTrue);
      expect(local.validUntil.isUtc, isTrue);
      expect(local.validUntil, DateTime.utc(2026, 7, 10, 13, 0));
    });

    test('ageAt returns elapsed time since fetch', () {
      expect(
        window.ageAt(DateTime.utc(2026, 7, 10, 12, 45)),
        const Duration(minutes: 45),
      );
    });

    test('round-trips through JSON', () {
      final restored = FreshnessWindow.fromJson(window.toJson());
      expect(restored.fetchedAt, window.fetchedAt);
      expect(restored.validUntil, window.validUntil);
    });
  });
}
