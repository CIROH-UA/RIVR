import 'package:get_it/get_it.dart';
import 'package:rivr/services/4_infrastructure/map/map_service_factory.dart';
import 'package:rivr/services/4_infrastructure/map/flood_tileset_service.dart';

void setupMapDependencies() {
  final sl = GetIt.instance;
  if (sl.isRegistered<MapServiceFactory>()) return;

  // Map service factory (produces fresh page-scoped services)
  // Singleton: one Remote Config fetch per launch, shared by every map that
  // asks which flood tileset is current.
  sl.registerLazySingleton<FloodTilesetService>(() => FloodTilesetService());

  sl.registerFactory<MapServiceFactory>(() => MapServiceFactory());
}
