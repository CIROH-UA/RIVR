import 'package:get_it/get_it.dart';
import 'package:rivr/services/3_datasources/features/settings/settings_firestore_datasource.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/4_infrastructure/settings/user_settings_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/i_background_image_service.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/services/4_infrastructure/fcm/fcm_service.dart';
import 'package:rivr/services/1_contracts/features/settings/i_settings_repository.dart';
import 'package:rivr/services/2_coordinators/features/settings/settings_repository_impl.dart';
import 'package:rivr/models/2_usecases/features/settings/get_user_settings_usecase.dart';
import 'package:rivr/models/2_usecases/features/settings/update_flow_unit_usecase.dart';
import 'package:rivr/models/2_usecases/features/settings/update_notifications_usecase.dart';
import 'package:rivr/models/2_usecases/features/settings/update_notification_frequency_usecase.dart';
import 'package:rivr/models/2_usecases/features/settings/sync_settings_after_login_usecase.dart';

void setupSettingsDependencies() {
  final sl = GetIt.instance;
  if (sl.isRegistered<IUserSettingsService>()) return;

  // Datasource
  sl.registerLazySingleton<SettingsFirestoreDatasource>(
    () => SettingsFirestoreDatasource(),
  );

  // Service
  sl.registerLazySingleton<IUserSettingsService>(
    () => UserSettingsService(
      datasource: sl<SettingsFirestoreDatasource>(),
      unitService: sl<IFlowUnitPreferenceService>(),
      imageService: sl<IBackgroundImageService>(),
    ),
  );

  // FCM service (depends on settings service)
  sl.registerLazySingleton<IFCMService>(
    () => FCMService(settingsService: sl<IUserSettingsService>()),
  );

  // Repository
  sl.registerLazySingleton<ISettingsRepository>(
    () => SettingsRepositoryImpl(settingsService: sl<IUserSettingsService>()),
  );

  // Use cases
  sl.registerFactory(() => GetUserSettingsUseCase(sl<ISettingsRepository>()));
  sl.registerFactory(() => UpdateFlowUnitUseCase(sl<ISettingsRepository>()));
  sl.registerFactory(() => UpdateNotificationsUseCase(sl<ISettingsRepository>()));
  sl.registerFactory(() => UpdateNotificationFrequencyUseCase(sl<ISettingsRepository>()));
  sl.registerFactory(() => SyncSettingsAfterLoginUseCase(sl<ISettingsRepository>()));
}
