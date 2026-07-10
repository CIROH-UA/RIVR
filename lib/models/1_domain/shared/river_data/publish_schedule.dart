// lib/models/1_domain/shared/river_data/publish_schedule.dart

/// Pure helpers for computing the *next possible publish time* of an upstream
/// source, used by data sources to set a payload's [FreshnessWindow.validUntil]
/// (ADR 0001, decision D3: publish-aligned TTL). All math is in UTC so it stays
/// correct across the GEOGLOWS 00Z boundary and NWM's server timezone / DST.
///
/// "Next" means strictly after [now] — a value fetched exactly on a boundary is
/// valid until the following one.
class PublishSchedule {
  const PublishSchedule._();

  /// Next top of the hour after [now] — hourly publishers (NWM analysis /
  /// short-range). 12:30 -> 13:00, 12:00 -> 13:00.
  static DateTime nextTopOfHour(DateTime now) {
    final u = now.toUtc();
    return DateTime.utc(u.year, u.month, u.day, u.hour).add(
      const Duration(hours: 1),
    );
  }

  /// Next [everyHours]-hour cycle boundary after [now], aligned to 00:00 UTC —
  /// NWM medium/long publish every 6 h at 00/06/12/18Z. Requires [everyHours] to
  /// divide 24. 13:10 -> 18:00 (6h), 18:00 -> 00:00 next day.
  static DateTime nextCycle(DateTime now, {required int everyHours}) {
    assert(everyHours > 0 && 24 % everyHours == 0, 'everyHours must divide 24');
    final u = now.toUtc();
    final dayStart = DateTime.utc(u.year, u.month, u.day);
    final cycleMinutes = everyHours * 60;
    final elapsed = u.difference(dayStart).inMinutes;
    final nextIndex = (elapsed ~/ cycleMinutes) + 1;
    return dayStart.add(Duration(minutes: nextIndex * cycleMinutes));
  }

  /// Next 00:00 UTC after [now] — daily publishers (GEOGLOWS 00Z run).
  static DateTime nextUtcMidnight(DateTime now) {
    final u = now.toUtc();
    return DateTime.utc(u.year, u.month, u.day).add(const Duration(days: 1));
  }
}
