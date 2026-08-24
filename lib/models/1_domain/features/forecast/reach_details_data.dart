// lib/models/1_domain/features/forecast/reach_details_data.dart

/// The narrow, display-ready detail bundle for one reach. Pure domain data —
/// moved out of the `IForecastService` contract in ADR 0011 Phase 3 so UI
/// surfaces can carry it without importing the fetch layer.
class ReachDetailsData {
  final String? riverName;
  final String? formattedLocation;
  final double? currentFlow;
  final String? flowCategory;
  final double? latitude;
  final double? longitude;
  final bool isClassificationAvailable;

  /// Raw return-period thresholds (return year -> flow, in native units), when
  /// available. The map bottom sheet uses the pre-computed [flowCategory]; the
  /// favorites cards need these raw thresholds to compute their own flood
  /// category + risk video.
  final Map<int, double>? returnPeriods;

  const ReachDetailsData({
    this.riverName,
    this.formattedLocation,
    this.currentFlow,
    this.flowCategory,
    this.latitude,
    this.longitude,
    this.isClassificationAvailable = false,
    this.returnPeriods,
  });
}
