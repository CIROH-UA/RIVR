// lib/models/1_domain/shared/river_data/river_data_key.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';

/// The identity of one cacheable piece of river data: which [source], which
/// reach, which [product]. This is the single key the shared cache and the
/// repository index on (ADR 0001, decision D2). Including [source] means two
/// sources can never collide even if they share a reach-id namespace.
///
/// Immutable and value-equal, so it is safe to use as a `Map`/`Set` key and to
/// compare across widgets subscribing to the same data.
class RiverDataKey {
  final ForecastSource source;
  final String reachId;
  final ForecastProduct product;

  const RiverDataKey({
    required this.source,
    required this.reachId,
    required this.product,
  });

  /// Filesystem-safe, stable, human-readable identifier used for disk cache
  /// filenames and in-memory map keys, e.g. `nwm__23021904__shortRange`.
  String get storageKey => '${source.id}__${reachId}__${product.id}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RiverDataKey &&
          runtimeType == other.runtimeType &&
          source == other.source &&
          reachId == other.reachId &&
          product == other.product;

  @override
  int get hashCode => Object.hash(source, reachId, product);

  @override
  String toString() => 'RiverDataKey($storageKey)';
}
