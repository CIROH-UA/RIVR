// lib/models/1_domain/shared/river_data/freshness_window.dart

/// The freshness window of a cached river-data entry (ADR 0001, decision D3:
/// publish-aligned TTL + stale-while-revalidate).
///
/// [validUntil] is the point in time at which the upstream source could next
/// possibly have published new data (top of the next hour, the next 6-hour
/// cycle, the next daily 00Z run, ...). It is NOT an arbitrary TTL — it is
/// computed by each source from its publish schedule.
///
/// Read policy the repository applies:
///  - `isFreshAt(now)`  -> serve cached, make NO network call.
///  - `isStaleAt(now)`  -> serve cached immediately, THEN revalidate in the
///                          background and notify listeners (SWR).
///
/// Times are stored and compared in UTC to stay correct across the GEOGLOWS
/// 00Z boundary and NWM's server timezone / DST.
///
/// Named [FreshnessWindow] (not `CacheFreshness`) to avoid clashing with the
/// existing `enum CacheFreshness { fresh, stale }` in the cache contracts,
/// which is the *result* of a check; this is the *window* that decides it.
class FreshnessWindow {
  final DateTime fetchedAt;
  final DateTime validUntil;

  FreshnessWindow({required DateTime fetchedAt, required DateTime validUntil})
    : fetchedAt = fetchedAt.toUtc(),
      validUntil = validUntil.toUtc();

  /// Still reflects the latest possible publish — safe to serve without a fetch.
  bool isFreshAt(DateTime now) => now.toUtc().isBefore(validUntil);

  /// Past the publish boundary — serve, but revalidate.
  bool isStaleAt(DateTime now) => !isFreshAt(now);

  /// How long ago the value was fetched (for diagnostics / display).
  Duration ageAt(DateTime now) => now.toUtc().difference(fetchedAt);

  Map<String, dynamic> toJson() => {
    'fetchedAt': fetchedAt.toIso8601String(),
    'validUntil': validUntil.toIso8601String(),
  };

  factory FreshnessWindow.fromJson(Map<String, dynamic> json) => FreshnessWindow(
    fetchedAt: DateTime.parse(json['fetchedAt'] as String),
    validUntil: DateTime.parse(json['validUntil'] as String),
  );

  @override
  String toString() =>
      'FreshnessWindow(fetchedAt: ${fetchedAt.toIso8601String()}, '
      'validUntil: ${validUntil.toIso8601String()})';
}
