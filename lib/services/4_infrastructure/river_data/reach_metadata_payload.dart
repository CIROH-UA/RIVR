// lib/services/4_infrastructure/river_data/reach_metadata_payload.dart

import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';

/// The one definition of the NWM `reachMetadata` cache schema — a reach's
/// identity, with no flow data in it at all.
///
/// Split out of `reachSummary` for ADR 0011 Phase 1. The map detail sheet used
/// to wait on a single bundled read that fetched reach info, current flow,
/// return periods *and* a 156 KB medium-range forecast serially before drawing
/// anything — roughly 45 s at median. The forecast series was never rendered.
///
/// Nothing here is unit-dependent, so unlike the flow payloads there is no
/// read-time conversion: a river's name and coordinates are the same in CFS and
/// CMS. That is also why this carries a long freshness window.
class ReachMetadataPayload {
  const ReachMetadataPayload._();

  static Map<String, dynamic> encode(ReachMetadata m) => {
    'riverName': m.riverName,
    'formattedLocation': m.formattedLocation,
    'latitude': m.latitude,
    'longitude': m.longitude,
  };

  static ReachMetadata decode(RiverDataEntry entry) {
    final p = entry.payload;
    return ReachMetadata(
      riverName: p['riverName'] as String?,
      formattedLocation: p['formattedLocation'] as String?,
      latitude: (p['latitude'] as num?)?.toDouble(),
      longitude: (p['longitude'] as num?)?.toDouble(),
    );
  }
}

/// A reach's identity: what to call it and where it is.
class ReachMetadata {
  final String? riverName;
  final String? formattedLocation;
  final double? latitude;
  final double? longitude;

  const ReachMetadata({
    this.riverName,
    this.formattedLocation,
    this.latitude,
    this.longitude,
  });
}
