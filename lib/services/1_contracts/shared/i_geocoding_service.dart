// lib/services/1_contracts/shared/i_geocoding_service.dart

/// Reverse-geocoding, behind an interface so it can be substituted.
///
/// `GeocodingService` is a class of statics. That made two things impossible,
/// and review caught both:
///
///  1. **Nothing could pin that a geocode does NOT happen.** ADR 0011 Phase 1
///     moved geocoding off the critical path, because `reverseGeocode` catches
///     internally and never throws, so nothing bounded it but a 30 s HTTP
///     timeout sitting in front of the cheapest call in the app. The guard
///     written to prevent its return asserted on elapsed time — and a real
///     Mapbox call was measured returning in 86 ms, under the threshold. The
///     guard could not fail for the right reason.
///  2. **Nothing could pin that a geocode DOES happen.** `_fillPlaceLabel` is
///     now the only thing preserving the place label that the old bundled path
///     supplied, and deleting both call sites left the whole suite green.
///
/// It also meant widget tests made **live network calls** — two real Mapbox
/// requests per run of the forecast-page test — depending on internet and on a
/// gitignored token, so CI silently exercised a different path.
///
/// One seam fixes all three.
abstract class IGeocodingService {
  /// Reverse-geocode a coordinate to its parts. Best-effort: implementations
  /// return nulls rather than throwing.
  Future<Map<String, String?>> reverseGeocode(double latitude, double longitude);

  /// A human place label — "City, ST" inside the US, "City, Country" elsewhere.
  /// Null when the coordinates or the lookup yield nothing.
  Future<String?> placeLabel(double? latitude, double? longitude);
}
