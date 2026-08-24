// lib/services/3_datasources/features/auth/biometric_datasource.dart

import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Raw local_auth and secure storage operations for biometric authentication.
///
/// No business logic or error mapping — exceptions propagate to the coordinator.
class BiometricDatasource {
  final LocalAuthentication _localAuth;
  final FlutterSecureStorage _secureStorage;

  static const String _biometricEnabledKey = 'biometric_enabled';
  static const String _biometricUserIdKey = 'biometric_user_id';
  static const String _biometricEmailKey = 'biometric_email';

  BiometricDatasource({
    LocalAuthentication? localAuth,
    FlutterSecureStorage? secureStorage,
  })  : _localAuth = localAuth ?? LocalAuthentication(),
        _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
      // v11: everything is encrypted by default (the old
      // encryptedSharedPreferences flag is gone). Existing users' stored
      // values auto-migrate from the v9 cipher; migrateWithBackup makes that
      // migration crash-resistant so a kill mid-upgrade cannot eat the
      // biometric credentials.
      migrateWithBackup: true,
    ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  /// Whether the device supports biometric authentication.
  Future<bool> isAvailable() async {
    final canCheck = await _localAuth.canCheckBiometrics;
    final isSupported = await _localAuth.isDeviceSupported();
    return canCheck && isSupported;
  }

  /// Whether the user has opted in to biometric login.
  Future<bool> isEnabled() async {
    final value = await _secureStorage.read(key: _biometricEnabledKey);
    return value == 'true';
  }

  /// Prompt the user for biometric authentication.
  Future<bool> authenticate(String reason) async {
    // local_auth 3.0: AuthenticationOptions is gone; options are top-level
    // named params. stickyAuth became persistAcrossBackgrounding.
    return _localAuth
        .authenticate(
          localizedReason: reason,
          biometricOnly: true,
          persistAcrossBackgrounding: true,
        )
        .timeout(const Duration(seconds: 30), onTimeout: () => false);
  }

  /// Persist credentials to secure storage after enabling biometric login.
  Future<void> storeCredentials({
    required String userId,
    required String email,
  }) async {
    await _secureStorage.write(key: _biometricEnabledKey, value: 'true');
    await _secureStorage.write(key: _biometricUserIdKey, value: userId);
    await _secureStorage.write(key: _biometricEmailKey, value: email);
  }

  /// Read the stored user ID.
  Future<String?> getStoredUserId() async {
    return _secureStorage.read(key: _biometricUserIdKey);
  }

  /// Read the stored email.
  Future<String?> getStoredEmail() async {
    return _secureStorage.read(key: _biometricEmailKey);
  }

  /// Remove all biometric credentials from secure storage.
  Future<void> clearCredentials() async {
    await _secureStorage.delete(key: _biometricEnabledKey);
    await _secureStorage.delete(key: _biometricUserIdKey);
    await _secureStorage.delete(key: _biometricEmailKey);
  }
}
