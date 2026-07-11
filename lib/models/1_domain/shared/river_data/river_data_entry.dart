// lib/models/1_domain/shared/river_data/river_data_entry.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';

/// One cached unit of river data: its [key], its freshness [window], and the
/// [payload] itself.
///
/// [payload] is a product-specific JSON object stored in the flow [unit] it was
/// fetched in — the cache stays agnostic of NWM vs GEOGLOWS shapes (ADR 0001,
/// decision D2). The repository converts the payload's flow values from [unit]
/// to the user's current display unit at read time, so flipping CFS/CMS never
/// requires clearing the cache. Scalar payloads (e.g. a single current-flow
/// value) are wrapped in a small map by their producer so the envelope is
/// always a JSON object.
class RiverDataEntry {
  final RiverDataKey key;
  final FreshnessWindow window;

  /// The flow unit the [payload]'s values are stored in (e.g. `CFS`, `CMS`).
  /// Read-time conversion goes from this to the user's current unit.
  final String unit;
  final Map<String, dynamic> payload;

  const RiverDataEntry({
    required this.key,
    required this.window,
    required this.unit,
    required this.payload,
  });

  /// Convenience passthrough — cached value still reflects the latest publish.
  bool isFreshAt(DateTime now) => window.isFreshAt(now);

  Map<String, dynamic> toJson() => {
    'source': key.source.id,
    'reachId': key.reachId,
    'product': key.product.id,
    'window': window.toJson(),
    'unit': unit,
    'payload': payload,
  };

  factory RiverDataEntry.fromJson(Map<String, dynamic> json) => RiverDataEntry(
    key: RiverDataKey(
      source: ForecastSource.fromId(json['source'] as String?),
      reachId: json['reachId'] as String,
      product: ForecastProduct.fromId(json['product'] as String),
    ),
    window: FreshnessWindow.fromJson(json['window'] as Map<String, dynamic>),
    unit: json['unit'] as String,
    payload: Map<String, dynamic>.from(json['payload'] as Map),
  );

  @override
  String toString() => 'RiverDataEntry($key, $window, unit: $unit)';
}
