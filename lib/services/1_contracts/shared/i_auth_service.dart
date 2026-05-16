// lib/services/1_contracts/shared/i_auth_service.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:rivr/services/4_infrastructure/auth/auth_service.dart';

/// Interface for authentication operations
abstract class IAuthService {
  User? get currentUser;
  Stream<User?> get authStateChanges;
  bool get isSignedIn;
  Future<AuthResult> signInWithEmailAndPassword({
    required String email,
    required String password,
  });
  Future<AuthResult> registerWithEmailAndPassword({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  });
  Future<AuthResult> sendPasswordResetEmail({required String email});
  Future<AuthResult> signOut();
  Future<bool> isBiometricAvailable();
  Future<bool> isBiometricEnabled();
  Future<AuthResult> enableBiometricLogin();
  Future<AuthResult> disableBiometricLogin();
  Future<AuthResult> signInWithBiometrics();
  Future<AuthResult> updateDisplayName(String displayName);
  Future<void> reloadUser();
  Future<AuthResult> sendEmailVerification();
  Future<bool> checkEmailVerified();

  /// Reauthenticate the current user with their password.
  /// Required by Firebase before sensitive actions like account deletion.
  Future<AuthResult> reauthenticateWithPassword({required String password});

  /// Permanently delete the current Firebase Auth user and clear any local
  /// biometric credentials. Firestore + FCM cleanup must run *before* this
  /// call while the user is still authenticated.
  Future<AuthResult> deleteCurrentUser();
}
