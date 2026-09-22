// lib/services/3_datasources/features/auth/auth_firebase_datasource.dart

import 'package:firebase_auth/firebase_auth.dart';

/// Raw Firebase Auth SDK calls with no business logic or error mapping.
///
/// Exceptions propagate directly for the coordinator to handle.
class AuthFirebaseDatasource {
  final FirebaseAuth _firebaseAuth;

  AuthFirebaseDatasource({FirebaseAuth? firebaseAuth})
      : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance;

  User? get currentUser => _firebaseAuth.currentUser;

  Stream<User?> get authStateChanges => _firebaseAuth.authStateChanges();

  bool get isSignedIn => currentUser != null;

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    return _firebaseAuth
        .signInWithEmailAndPassword(email: email.trim(), password: password)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw FirebaseAuthException(
            code: 'timeout',
            message: 'Sign in request timed out',
          ),
        );
  }

  Future<UserCredential> register({
    required String email,
    required String password,
  }) async {
    return _firebaseAuth
        .createUserWithEmailAndPassword(
          email: email.trim(),
          password: password,
        )
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw FirebaseAuthException(
            code: 'timeout',
            message: 'Registration request timed out',
          ),
        );
  }

  /// ADR 0014 — guest identity. Firebase mints a uid with no credential.
  /// Throws `operation-not-allowed` when the provider is off in the console.
  Future<UserCredential> signInAnonymously() async {
    return _firebaseAuth.signInAnonymously().timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw FirebaseAuthException(
            code: 'timeout',
            message: 'Guest sign-in timed out',
          ),
        );
  }

  /// ADR 0014 — turn a guest into an account IN PLACE. The uid, and with it
  /// every Firestore document, survives; only the credential is added.
  /// Throws `email-already-in-use` / `credential-already-in-use` when the
  /// address already has an account (the caller offers Sign In instead).
  Future<UserCredential> linkWithEmailPassword({
    required User user,
    required String email,
    required String password,
  }) async {
    final credential = EmailAuthProvider.credential(
      email: email.trim(),
      password: password,
    );
    return user.linkWithCredential(credential).timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw FirebaseAuthException(
            code: 'timeout',
            message: 'Account creation timed out',
          ),
        );
  }

  Future<void> updateDisplayName(User user, String displayName) async {
    await user.updateDisplayName(displayName);
  }

  Future<void> sendEmailVerification(User user) async {
    await user.sendEmailVerification();
  }

  Future<void> sendPasswordResetEmail(String email) async {
    await _firebaseAuth
        .sendPasswordResetEmail(email: email.trim())
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw FirebaseAuthException(
            code: 'timeout',
            message: 'Password reset request timed out',
          ),
        );
  }

  Future<void> signOut() async {
    await _firebaseAuth.signOut().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        // Continue anyway — local session will be cleared
      },
    );
  }

  Future<void> reloadUser() async {
    await currentUser?.reload();
  }

  /// Returns the latest emailVerified flag after reloading.
  Future<bool> checkEmailVerified() async {
    if (currentUser == null) return false;
    await currentUser!.reload();
    return _firebaseAuth.currentUser?.emailVerified ?? false;
  }

  /// Reauthenticate the given user with email/password.
  /// Required by Firebase before sensitive operations like `delete()`.
  Future<void> reauthenticateWithPassword({
    required User user,
    required String email,
    required String password,
  }) async {
    final credential = EmailAuthProvider.credential(
      email: email.trim(),
      password: password,
    );
    await user
        .reauthenticateWithCredential(credential)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw FirebaseAuthException(
            code: 'timeout',
            message: 'Reauthentication request timed out',
          ),
        );
  }

  /// Permanently delete the Firebase Auth account for [user].
  /// Caller is responsible for any Firestore / messaging cleanup beforehand.
  Future<void> deleteUser(User user) async {
    await user.delete().timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw FirebaseAuthException(
            code: 'timeout',
            message: 'Account deletion request timed out',
          ),
        );
  }
}
