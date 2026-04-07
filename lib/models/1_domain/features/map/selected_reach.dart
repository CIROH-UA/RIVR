// lib/models/1_domain/features/map/selected_reach.dart

/// Lightweight model for river reach selections from vector tiles
/// Contains immediate data from vector tiles + async-loaded river name
class SelectedReach {
  // Immediate data from vector tiles
  final String reachId; // from station_id property
  final int streamOrder; // from streamOrder property
  final double latitude; // from tap location
  final double longitude; // from tap location

  // Async-loaded data from NOAA API
  final String? riverName; // loaded from NOAA reaches API
  final String? city; // geocoded location context
  final String? state; // geocoded location context

  // Selection metadata
  final DateTime selectedAt;

  const SelectedReach({
    required this.reachId,
    required this.streamOrder,
    required this.latitude,
    required this.longitude,
    this.riverName,
    this.city,
    this.state,
    required this.selectedAt,
  });

  /// Create from vector tile feature properties
  factory SelectedReach.fromVectorTile({
    required Map<String, dynamic> properties,
    required double latitude,
    required double longitude,
  }) {
    return SelectedReach(
      reachId: properties['station_id'].toString(),
      streamOrder: properties['streamOrder'] as int,
      latitude: latitude,
      longitude: longitude,
      selectedAt: DateTime.now(),
    );
  }

  /// Update with river name from NOAA API
  SelectedReach withRiverName(String riverName) {
    return SelectedReach(
      reachId: reachId,
      streamOrder: streamOrder,
      latitude: latitude,
      longitude: longitude,
      riverName: riverName,
      city: city,
      state: state,
      selectedAt: selectedAt,
    );
  }

  /// Update with location context
  SelectedReach withLocation({String? city, String? state}) {
    return SelectedReach(
      reachId: reachId,
      streamOrder: streamOrder,
      latitude: latitude,
      longitude: longitude,
      riverName: riverName,
      city: city ?? this.city,
      state: state ?? this.state,
      selectedAt: selectedAt,
    );
  }

  // Helper properties
  String get displayName => riverName ?? 'Stream $reachId';
  String get streamOrderDescription => _getStreamOrderDescription(streamOrder);
  String get formattedLocation =>
      city != null && state != null ? '$city, $state' : '';
  bool get hasRiverName => riverName != null && riverName!.isNotEmpty;
  bool get hasLocation => city != null || state != null;

  /// Get human-readable stream order description
  String _getStreamOrderDescription(int order) {
    if (order >= 8) return 'Major River';
    if (order >= 5) return 'Large Stream';
    if (order >= 3) return 'Medium Stream';
    return 'Small Stream';
  }

  /// Get coordinates as formatted string
  String get coordinatesString =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';

  @override
  String toString() {
    return 'SelectedReach(reachId: $reachId, riverName: $riverName, streamOrder: $streamOrder)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SelectedReach && other.reachId == reachId;
  }

  @override
  int get hashCode => reachId.hashCode;
}
