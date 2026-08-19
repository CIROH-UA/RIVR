// lib/services/4_infrastructure/map/map_service_factory.dart

import 'package:get_it/get_it.dart';
import 'package:rivr/services/4_infrastructure/map/flood_tileset_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_vector_tiles_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_reach_selection_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_marker_service.dart';
import 'package:rivr/services/4_infrastructure/map/map_controls_service.dart';

/// Factory for creating page-scoped map services.
/// Registered as a factory in GetIt so each MapPage gets fresh instances.
/// Enables mock injection in tests without changing service lifecycle.
class MapServiceFactory {
  MapVectorTilesService createVectorTilesService() =>
      MapVectorTilesService(floodTilesets: GetIt.I<FloodTilesetService>());
  MapReachSelectionService createReachSelectionService() =>
      MapReachSelectionService();
  MapMarkerService createMarkerService() => MapMarkerService();
  MapControlsService createControlsService() => MapControlsService();
}
