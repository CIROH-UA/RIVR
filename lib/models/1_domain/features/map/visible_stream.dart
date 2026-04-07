// lib/models/1_domain/features/map/visible_stream.dart

/// Simple model for a visible stream in the map list
/// Contains immediate data extracted from vector tile queries
class VisibleStream {
  final String stationId;
  final int streamOrder;
  final double latitude;
  final double longitude;
  final String? riverName; // Optional, may be loaded later

  const VisibleStream({
    required this.stationId,
    required this.streamOrder,
    required this.latitude,
    required this.longitude,
    this.riverName,
  });

  String get displayName => riverName ?? 'Stream $stationId';

  String get coordinates =>
      '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VisibleStream && other.stationId == stationId;
  }

  @override
  int get hashCode => stationId.hashCode;

  @override
  String toString() {
    return 'VisibleStream{stationId: $stationId, streamOrder: $streamOrder, coordinates: ($latitude, $longitude)}';
  }
}
