import 'package:get_it/get_it.dart';
import 'package:rivr/services/4_infrastructure/map/map_service_factory.dart';

void setupMapDependencies() {
  final sl = GetIt.instance;
  if (sl.isRegistered<MapServiceFactory>()) return;

  // Map service factory (produces fresh page-scoped services)
  sl.registerFactory<MapServiceFactory>(() => MapServiceFactory());
}
