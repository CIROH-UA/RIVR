import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/shared/flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_cache_service.dart';
import 'package:rivr/services/4_infrastructure/cache/cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_reach_cache_service.dart';
import 'package:rivr/services/4_infrastructure/cache/reach_cache_service.dart';
import 'package:rivr/services/1_contracts/shared/i_background_image_service.dart';
import 'package:rivr/services/4_infrastructure/media/background_image_service.dart';

void setupSharedDependencies() {
  final sl = GetIt.instance;
  if (sl.isRegistered<IFlowUnitPreferenceService>()) return;

  sl.registerLazySingleton<IFlowUnitPreferenceService>(
    () => FlowUnitPreferenceService(),
  );
  sl.registerLazySingleton<ICacheService>(() => CacheService());
  sl.registerLazySingleton<IReachCacheService>(() => ReachCacheService());
  sl.registerLazySingleton<IBackgroundImageService>(
    () => BackgroundImageService(),
  );
}
