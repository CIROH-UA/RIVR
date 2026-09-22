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

  /// ADR 0014 — sign in as a guest and make sure a `users/{uid}` document
  /// exists with `isGuest: true`. Safe to call when already signed in: it
  /// returns the current user untouched.
  Future<AuthResult> signInAnonymously();

  /// ADR 0014 — record a sign of life for guest garbage collection. Never
  /// throws; a failed write is logged and ignored.
  Future<void> touchLastActive(String userId);

  /// ADR 0014 UX-3 — the one "create an account" prompt has been shown to
  /// this identity. Never throws.
  Future<void> markAccountPromptShown(String userId);
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
