// lib/services/4_infrastructure/river_data/source_registry.dart

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';

/// Resolves a [ForecastSource] (or a [RiverDataKey]) to its [IRiverDataSource]
/// (ADR 0001, decision D4). This is what replaces the scattered
/// `if (source.isGeoglows)` branches: the repository and router look a source
/// up here instead of hard-coding a two-way choice, so a third source is a
/// registration, not an edit across the codebase.
class SourceRegistry {
  SourceRegistry(Iterable<IRiverDataSource> sources)
    : _bySource = {for (final s in sources) s.source: s};

  final Map<ForecastSource, IRiverDataSource> _bySource;

  bool has(ForecastSource source) => _bySource.containsKey(source);

  IRiverDataSource forSource(ForecastSource source) {
    final resolved = _bySource[source];
    if (resolved == null) {
      throw StateError('No IRiverDataSource registered for $source');
    }
    return resolved;
  }

  IRiverDataSource forKey(RiverDataKey key) => forSource(key.source);

  Iterable<IRiverDataSource> get all => _bySource.values;
}
