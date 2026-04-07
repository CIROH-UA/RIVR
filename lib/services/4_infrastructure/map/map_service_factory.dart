// lib/services/4_infrastructure/map/map_service_factory.dart

import 'package:rivr/services/4_infrastructure/map/map_vector_tiles_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_reach_selection_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_marker_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_controls_service.dart';

/// Factory for creating page-scoped map services.
/// Registered as a factory in GetIt so each MapPage gets fresh instances.
/// Enables mock injection in tests without changing service lifecycle.
class MapServiceFactory {
  MapVectorTilesService createVectorTilesService() => MapVectorTilesService();
  MapReachSelectionService createReachSelectionService() =>
      MapReachSelectionService();
  MapMarkerService createMarkerService() => MapMarkerService();
  MapControlsService createControlsService() => MapControlsService();
}
