import 'package:get_it/get_it.dart';
import 'package:rivr/services/3_datasources/features/auth/auth_firebase_datasource.dart';
import 'package:rivr/services/3_datasources/features/auth/biometric_datasource.dart';
import 'package:rivr/services/1_contracts/shared/i_auth_service.dart';
import 'package:rivr/services/4_infrastructure/auth/auth_service.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';
import 'package:rivr/services/2_coordinators/features/auth/auth_repository_impl.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_up_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_out_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/reset_password_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/get_auth_state_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_with_biometrics_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/enable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/disable_biometric_usecase.dart';

void setupAuthDependencies() {
  final sl = GetIt.instance;
  if (sl.isRegistered<IAuthService>()) return;

  // Datasources
  sl.registerLazySingleton<AuthFirebaseDatasource>(
    () => AuthFirebaseDatasource(),
  );
  sl.registerLazySingleton<BiometricDatasource>(
    () => BiometricDatasource(),
  );

  // Service
  sl.registerLazySingleton<IAuthService>(
    () => AuthService(
      authDatasource: sl<AuthFirebaseDatasource>(),
      biometricDatasource: sl<BiometricDatasource>(),
    ),
  );

  // Repository
  sl.registerLazySingleton<IAuthRepository>(
    () => AuthRepositoryImpl(
      authService: sl<IAuthService>(),
      settingsService: sl<IUserSettingsService>(),
    ),
  );

  // Use cases
  sl.registerFactory(() => SignInUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => SignUpUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => SignOutUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => ResetPasswordUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => GetAuthStateUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => SignInWithBiometricsUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => EnableBiometricUseCase(sl<IAuthRepository>()));
  sl.registerFactory(() => DisableBiometricUseCase(sl<IAuthRepository>()));
}
