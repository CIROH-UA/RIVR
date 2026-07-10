// lib/models/1_domain/shared/river_data/river_data_entry.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';

/// One cached unit of river data: its [key], its freshness [window], and the
/// [payload] itself.
///
/// [payload] is a **native-unit** (m³/s), product-specific JSON object — the
/// cache stays agnostic of NWM vs GEOGLOWS shapes (ADR 0001, decision D2); the
/// source adapter that produced it knows how to (de)serialize it, and the
/// repository converts to the user's display unit at read time. Scalar payloads
/// (e.g. a single current-flow value) are wrapped in a small map by their
/// producer so the envelope is always a JSON object.
class RiverDataEntry {
  final RiverDataKey key;
  final FreshnessWindow window;
  final Map<String, dynamic> payload;

  const RiverDataEntry({
    required this.key,
    required this.window,
    required this.payload,
  });

  /// Convenience passthrough — cached value still reflects the latest publish.
  bool isFreshAt(DateTime now) => window.isFreshAt(now);

  Map<String, dynamic> toJson() => {
    'source': key.source.id,
    'reachId': key.reachId,
    'product': key.product.id,
    'window': window.toJson(),
    'payload': payload,
  };

  factory RiverDataEntry.fromJson(Map<String, dynamic> json) => RiverDataEntry(
    key: RiverDataKey(
      source: ForecastSource.fromId(json['source'] as String?),
      reachId: json['reachId'] as String,
      product: ForecastProduct.fromId(json['product'] as String),
    ),
    window: FreshnessWindow.fromJson(json['window'] as Map<String, dynamic>),
    payload: Map<String, dynamic>.from(json['payload'] as Map),
  );

  @override
  String toString() => 'RiverDataEntry($key, $window)';
}
