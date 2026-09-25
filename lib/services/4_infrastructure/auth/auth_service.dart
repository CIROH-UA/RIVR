// lib/services/4_infrastructure/auth/auth_service.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:rivr/services/3_datasources/shared/dtos/user_settings_dto.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/shared/error_service.dart';
import 'package:rivr/services/1_contracts/shared/i_auth_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/services/3_datasources/features/auth/auth_firebase_datasource.dart';
import 'package:rivr/services/3_datasources/features/auth/biometric_datasource.dart';

/// Firebase Auth wrapper service for RIVR.
///
/// Delegates raw Firebase Auth calls to [AuthFirebaseDatasource] and
/// biometric operations to [BiometricDatasource]. Implements [IAuthService]
/// for backward compatibility with consumers (e.g. [AuthProvider]) that
/// haven't migrated to use cases yet.
class AuthService implements IAuthService {
  final AuthFirebaseDatasource _authDatasource;
  final BiometricDatasource _biometricDatasource;
  // Injectable so the ADR 0014 guest/merge paths can be tested against a fake
  // Firestore. Everything else in this class predates the split and reached
  // for the singleton directly.
  final FirebaseFirestore _firestore;

  AuthService({
    AuthFirebaseDatasource? authDatasource,
    BiometricDatasource? biometricDatasource,
    FirebaseFirestore? firestore,
  })  : _authDatasource = authDatasource ?? AuthFirebaseDatasource(),
        _biometricDatasource = biometricDatasource ?? BiometricDatasource(),
        _firestore = firestore ?? FirebaseFirestore.instance;

  /// Get current Firebase user
  @override
  User? get currentUser => _authDatasource.currentUser;

  /// Stream of authentication state changes
  @override
  Stream<User?> get authStateChanges => _authDatasource.authStateChanges;

  /// Check if user is currently signed in
  @override
  bool get isSignedIn => _authDatasource.isSignedIn;

  // MARK: - Email/Password Authentication

  /// Sign in with email and password
  @override
  Future<AuthResult> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    // ADR 0014 B6 — a guest signing into an account they already have. Their
    // rivers must follow them.
    //
    // NOTHING IS WRITTEN UNTIL THE SIGN-IN HAS SUCCEEDED. The first version
    // of this cleared the guest's favourites BEFORE the attempt so an
    // orphaned document could not keep driving alerts, and restored them if
    // the sign-in failed. On its first real use (2026-09-22, build 832) the
    // restore did not happen and a tester's two saved rivers were destroyed
    // — the document was left with `mergePending: true` and an empty
    // favourites list. A design that destroys data first and repairs it
    // afterwards only has to fail once, and it fails on the network, which
    // is exactly when it is least able to repair anything.
    //
    // The abandoned document is now handled the only safe way round: read
    // it, sign in, merge, then delete. If the delete fails, `guestGcDaily`
    // sweeps it later — a guest document that lingers is a cost, while a
    // guest document that is emptied is lost data.
    final guest = currentUser;
    final bool fromGuest = guest != null && guest.isAnonymous;
    final Map<String, dynamic>? guestDoc =
        fromGuest ? await _readUserDoc(guest.uid) : null;

    try {
      AppLogger.debug('AuthService', 'Signing in with email: $email');

      final credential = await _authDatasource.signIn(
        email: email,
        password: password,
      );

      if (credential.user == null) {
        return AuthResult.failure('Sign in failed - no user returned');
      }

      if (fromGuest) {
        if (guestDoc != null) {
          await _mergeGuestIntoAccount(credential.user!.uid, guestDoc);
        }
        await _deleteAbandonedGuest(guest);
      }

      AppLogger.info('AuthService', 'Sign in successful for user: ${credential.user!.uid}');
      return AuthResult.success(credential.user!);
    } on FirebaseAuthException catch (e) {
      AppLogger.error('AuthService', 'FirebaseAuthException: ${e.code} - ${e.message}', e);
      return AuthResult.failure(ErrorService.mapFirebaseAuthError(e));
    } catch (e) {
      AppLogger.error('AuthService', 'Unexpected sign in error: $e', e);
      return AuthResult.failure('Sign in failed: ${e.toString()}');
    }
  }

  /// Register with email and password
  @override
  Future<AuthResult> registerWithEmailAndPassword({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    try {
      AppLogger.debug('AuthService', 'Registering user with email: $email');

      // ADR 0014 B5 — a guest becomes an account IN PLACE: the credential is
      // linked to the existing uid, so favourites, alerts and settings are
      // untouched and nothing migrates. A brand-new user (no session at all,
      // e.g. anonymous sign-in refused offline) takes the old create path.
      final guest = currentUser;
      final bool linking = guest != null && guest.isAnonymous;

      final UserCredential credential = linking
          ? await _authDatasource.linkWithEmailPassword(
              user: guest,
              email: email,
              password: password,
            )
          : await _authDatasource.register(
              email: email,
              password: password,
            );

      // linkWithCredential may hand back a credential whose user is null on
      // some platforms; the linked identity is still the current user.
      final user = credential.user ?? (linking ? currentUser : null);
      if (user == null) {
        return AuthResult.failure('Registration failed - no user returned');
      }
      AppLogger.info(
        'AuthService',
        '${linking ? 'Guest linked to account' : 'Registration successful'} '
        'for user: ${user.uid}',
      );

      // Update display name
      await _authDatasource.updateDisplayName(user, '$firstName $lastName');

      if (linking) {
        // The document already exists (created at guest sign-in). Add the
        // identity and drop the guest flag; everything else stays.
        await _updateUserDoc(user.uid, {
          'email': email.trim(),
          'firstName': firstName,
          'lastName': lastName,
          'isGuest': false,
          'updatedAt': DateTime.now().toIso8601String(),
        });
      } else {
        // Create UserSettings document in Firestore
        await _createUserSettings(
          userId: user.uid,
          email: email.trim(),
          firstName: firstName,
          lastName: lastName,
        );
      }

      // Send email verification (fire-and-forget)
      try {
        await _authDatasource.sendEmailVerification(user);
        AppLogger.info('AuthService', 'Verification email sent to ${email.trim()}');
      } catch (e) {
        AppLogger.warning('AuthService', 'Failed to send verification email: $e');
      }

      return AuthResult.success(user);
    } on FirebaseAuthException catch (e) {
      AppLogger.error('AuthService', 'Registration FirebaseAuthException: ${e.code} - ${e.message}', e);
      return AuthResult.failure(ErrorService.mapFirebaseAuthError(e));
    } catch (e) {
      AppLogger.error('AuthService', 'Unexpected registration error: $e', e);
      return AuthResult.failure('Registration failed: ${e.toString()}');
    }
  }

  // MARK: - Guest mode (ADR 0014)

  /// Sign in as a guest and guarantee a `users/{uid}` document.
  ///
  /// Idempotent: an existing session (guest or account) is returned as is.
  /// The document is created here because nothing else does — ADR 0014 M5:
  /// `register` was the only path that ever wrote it.
  @override
  Future<AuthResult> signInAnonymously() async {
    final existing = currentUser;
    if (existing != null) {
      return AuthResult.success(existing);
    }
    try {
      AppLogger.debug('AuthService', 'Signing in as guest');
      final credential = await _authDatasource.signInAnonymously();
      final user = credential.user;
      if (user == null) {
        return AuthResult.failure('Guest sign-in failed - no user returned');
      }
      AppLogger.info('AuthService', 'Guest signed in: ${user.uid}');

      // Belt and braces for the same defect: a document that exists but has
      // no `userId` is a stub, not settings, and must be filled in rather
      // than trusted. Checking only for existence is what let the stub
      // survive.
      final doc = await _readUserDoc(user.uid);
      if (doc == null || doc['userId'] == null) {
        await _createUserSettings(
          userId: user.uid,
          email: '',
          firstName: '',
          lastName: '',
          isGuest: true,
        );
      }
      return AuthResult.success(user);
    } on FirebaseAuthException catch (e) {
      AppLogger.error(
          'AuthService', 'Guest sign-in FirebaseAuthException: ${e.code} - ${e.message}', e);
      return AuthResult.failure(ErrorService.mapFirebaseAuthError(e));
    } catch (e) {
      AppLogger.error('AuthService', 'Unexpected guest sign-in error: $e', e);
      return AuthResult.failure('Guest sign-in failed: ${e.toString()}');
    }
  }

  /// Record a sign of life. `guestGcDaily` reaps guests whose `lastActiveAt`
  /// is older than its window, so this must run on every launch and must
  /// never break the launch when it fails.
  @override
  Future<void> touchLastActive(String userId) async {
    try {
      // `update`, never `set(merge:)` — this must NOT be able to create the
      // document. It used to, and that broke guest mode outright in build
      // 838: the auth-state listener fires the moment the anonymous user
      // exists and calls this, which created a STUB holding nothing but
      // `lastActiveAt`. `signInAnonymously` then saw a document already
      // there, skipped writing the real settings, and every later read blew
      // up on the missing `userId` — favourites could not be saved at all.
      //
      // If the document does not exist yet, this throws and is swallowed;
      // the next launch, once the settings exist, records the sign of life.
      await _users
          .doc(userId)
          .update({'lastActiveAt': DateTime.now().toIso8601String()})
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      AppLogger.warning('AuthService', 'lastActiveAt write skipped: $e');
    }
  }

  @override
  Future<void> markAccountPromptShown(String userId) async {
    try {
      await _updateUserDoc(userId, {'accountPromptShown': true});
    } catch (e) {
      AppLogger.warning('AuthService', 'accountPromptShown write failed: $e');
    }
  }

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  Future<Map<String, dynamic>?> _readUserDoc(String uid) async {
    try {
      final snap = await _users
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 10));
      return snap.exists ? snap.data() : null;
    } catch (e) {
      AppLogger.warning('AuthService', 'read users/$uid failed: $e');
      return null;
    }
  }

  Future<void> _updateUserDoc(String uid, Map<String, dynamic> fields) =>
      _users
          .doc(uid)
          .set(fields, SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));

  /// Union the guest's rivers into the account. The account's own values win
  /// on every conflict — a custom name the person chose on their phone last
  /// year beats one they typed as a guest yesterday.
  Future<void> _mergeGuestIntoAccount(
      String accountUid, Map<String, dynamic> guest) async {
    try {
      final account = await _readUserDoc(accountUid) ?? <String, dynamic>{};
      List<String> ids(Map<String, dynamic> d) =>
          List<String>.from(d['favoriteReachIds'] as List? ?? const []);
      Map<String, String> strMap(Map<String, dynamic> d, String k) =>
          (d[k] as Map?)?.map((a, b) => MapEntry(a.toString(), b.toString())) ??
          <String, String>{};

      final mergedIds = [
        ...ids(account),
        ...ids(guest).where((id) => !ids(account).contains(id)),
      ];
      Map<String, String> mergedMap(String k) =>
          {...strMap(guest, k), ...strMap(account, k)};

      final added = mergedIds.length - ids(account).length;
      if (added == 0 && strMap(guest, 'favoriteLabels').isEmpty) {
        AppLogger.info('AuthService', 'Guest had nothing to merge');
        return;
      }
      await _updateUserDoc(accountUid, {
        'favoriteReachIds': mergedIds,
        'favoriteSources': mergedMap('favoriteSources'),
        'favoriteLabels': mergedMap('favoriteLabels'),
        'alertFrequencies': mergedMap('alertFrequencies'),
        'updatedAt': DateTime.now().toIso8601String(),
      });
      AppLogger.info(
          'AuthService', 'Merged $added guest river(s) into $accountUid');
    } catch (e) {
      // The guest doc was neutralised, so nothing keeps firing; the rivers
      // are what is lost if this fails, and that is logged loudly.
      AppLogger.error('AuthService', 'guest merge into $accountUid failed: $e', e);
    }
  }

  /// Delete the guest identity after its rivers have moved. ADR 0014 U3/B6:
  /// whether `User.delete()` works on a user object that is no longer
  /// current is not verified — so this is best effort, and the neutralised
  /// document is inert either way until `guestGcDaily` reaps it.
  Future<void> _deleteAbandonedGuest(User guest) async {
    try {
      await _users.doc(guest.uid).delete().timeout(const Duration(seconds: 10));
    } catch (e) {
      AppLogger.warning('AuthService', 'delete guest doc ${guest.uid}: $e');
    }
    try {
      await _authDatasource.deleteUser(guest);
      AppLogger.info('AuthService', 'Abandoned guest ${guest.uid} deleted');
    } catch (e) {
      AppLogger.warning(
          'AuthService', 'guest ${guest.uid} left for guestGcDaily: $e');
    }
  }

  /// Create UserSettings document after successful registration — or, for a
  /// guest (ADR 0014), at first anonymous sign-in with no identity fields.
  Future<void> _createUserSettings({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
    bool isGuest = false,
  }) async {
    try {
      AppLogger.debug('AuthService', 'Creating UserSettings for user: $userId');

      final userSettings = UserSettings(
        userId: userId,
        email: email,
        firstName: firstName,
        lastName: lastName,
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twelveHour,
        enableNotifications: false,
        favoriteReachIds: [],
        lastLoginDate: DateTime.now(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        isGuest: isGuest,
        lastActiveAt: DateTime.now(),
      );

      await _users
          .doc(userId)
          .set(UserSettingsDto.fromEntity(userSettings).toJson())
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('UserSettings creation timed out'),
          );

      AppLogger.info('AuthService', 'UserSettings created successfully');
    } catch (e) {
      AppLogger.error('AuthService', 'Error creating UserSettings: $e', e);
      // Don't throw - registration was successful, this is just cleanup
    }
  }

  /// Send password reset email
  @override
  Future<AuthResult> sendPasswordResetEmail({required String email}) async {
    try {
      AppLogger.debug('AuthService', 'Sending password reset email to: $email');

      await _authDatasource.sendPasswordResetEmail(email);

      AppLogger.info('AuthService', 'Password reset email sent successfully');
      return AuthResult.success(null, message: 'Password reset email sent');
    } on FirebaseAuthException catch (e) {
      AppLogger.error('AuthService', 'Password reset FirebaseAuthException: ${e.code} - ${e.message}', e);
      return AuthResult.failure(ErrorService.mapFirebaseAuthError(e));
    } catch (e) {
      AppLogger.error('AuthService', 'Unexpected password reset error: $e', e);
      return AuthResult.failure(
        'Failed to send password reset email: ${e.toString()}',
      );
    }
  }

  /// Sign out current user
  @override
  Future<AuthResult> signOut() async {
    try {
      AppLogger.debug('AuthService', 'Signing out current user');

      await _authDatasource.signOut();

      // Clear biometric credentials on sign out
      await _biometricDatasource.clearCredentials();

      AppLogger.info('AuthService', 'Sign out successful');
      return AuthResult.success(null, message: 'Signed out successfully');
    } catch (e) {
      AppLogger.error('AuthService', 'Sign out error: $e', e);
      return AuthResult.failure('Sign out failed: ${e.toString()}');
    }
  }

  // MARK: - Biometric Authentication

  /// Check if device supports biometric authentication
  @override
  Future<bool> isBiometricAvailable() async {
    try {
      return await _biometricDatasource.isAvailable();
    } catch (e) {
      AppLogger.error('AuthService', 'Error checking biometric availability: $e', e);
      return false;
    }
  }

  /// Check if user has enabled biometric login
  @override
  Future<bool> isBiometricEnabled() async {
    try {
      return await _biometricDatasource.isEnabled();
    } catch (e) {
      AppLogger.error('AuthService', 'Error checking biometric enabled status: $e', e);
      return false;
    }
  }

  /// Enable biometric login for current user
  @override
  Future<AuthResult> enableBiometricLogin() async {
    try {
      if (currentUser == null) {
        return AuthResult.failure('No user signed in');
      }

      if (!await isBiometricAvailable()) {
        return AuthResult.failure('Biometric authentication not available');
      }

      // Authenticate with biometrics to confirm setup
      final authenticated = await _biometricDatasource.authenticate(
        'Authenticate to enable biometric login',
      );

      if (!authenticated) {
        return AuthResult.failure('Biometric authentication failed');
      }

      // Store credentials securely
      await _biometricDatasource.storeCredentials(
        userId: currentUser!.uid,
        email: currentUser!.email ?? '',
      );

      AppLogger.info('AuthService', 'Biometric login enabled successfully');
      return AuthResult.success(null, message: 'Biometric login enabled');
    } catch (e) {
      AppLogger.error('AuthService', 'Error enabling biometric login: $e', e);
      return AuthResult.failure(
        'Failed to enable biometric login: ${e.toString()}',
      );
    }
  }

  /// Disable biometric login
  @override
  Future<AuthResult> disableBiometricLogin() async {
    try {
      await _biometricDatasource.clearCredentials();
      AppLogger.info('AuthService', 'Biometric login disabled successfully');
      return AuthResult.success(null, message: 'Biometric login disabled');
    } catch (e) {
      AppLogger.error('AuthService', 'Error disabling biometric login: $e', e);
      return AuthResult.failure(
        'Failed to disable biometric login: ${e.toString()}',
      );
    }
  }

  /// Sign in using biometric authentication
  @override
  Future<AuthResult> signInWithBiometrics() async {
    try {
      if (!await isBiometricAvailable()) {
        return AuthResult.failure('Biometric authentication not available');
      }

      if (!await _biometricDatasource.isEnabled()) {
        return AuthResult.failure('Biometric login not enabled');
      }

      // Get stored credentials
      final userId = await _biometricDatasource.getStoredUserId();
      final email = await _biometricDatasource.getStoredEmail();

      if (userId == null || email == null) {
        return AuthResult.failure('No biometric credentials found');
      }

      // Authenticate with biometrics
      final authenticated = await _biometricDatasource.authenticate(
        'Use biometric authentication to sign in',
      );

      if (!authenticated) {
        return AuthResult.failure('Biometric authentication failed');
      }

      // Check if user still exists in Firebase
      if (currentUser?.uid != userId) {
        await _biometricDatasource.clearCredentials();
        return AuthResult.failure('Biometric credentials no longer valid');
      }

      AppLogger.info('AuthService', 'Biometric sign in successful for user: $userId');
      return AuthResult.success(
        currentUser!,
        message: 'Biometric sign in successful',
      );
    } catch (e) {
      AppLogger.error('AuthService', 'Biometric sign in error: $e', e);
      return AuthResult.failure('Biometric sign in failed: ${e.toString()}');
    }
  }

  // MARK: - User Profile Management

  /// Update user display name
  @override
  Future<AuthResult> updateDisplayName(String displayName) async {
    try {
      if (currentUser == null) {
        return AuthResult.failure('No user signed in');
      }

      await _authDatasource.updateDisplayName(currentUser!, displayName);
      AppLogger.info('AuthService', 'Display name updated successfully');
      return AuthResult.success(currentUser!, message: 'Display name updated');
    } catch (e) {
      AppLogger.error('AuthService', 'Error updating display name: $e', e);
      return AuthResult.failure(
        'Failed to update display name: ${e.toString()}',
      );
    }
  }

  /// Reload current user data
  @override
  Future<void> reloadUser() async {
    try {
      await _authDatasource.reloadUser();
    } catch (e) {
      AppLogger.error('AuthService', 'Error reloading user: $e', e);
    }
  }

  // MARK: - Email Verification

  /// Send email verification to current user
  @override
  Future<AuthResult> sendEmailVerification() async {
    try {
      if (currentUser == null) {
        return AuthResult.failure('No user signed in');
      }

      await _authDatasource.sendEmailVerification(currentUser!);

      AppLogger.info('AuthService', 'Verification email sent');
      return AuthResult.success(null, message: 'Verification email sent');
    } catch (e) {
      AppLogger.error('AuthService', 'Error sending verification email: $e', e);
      return AuthResult.failure('Failed to send verification email: ${e.toString()}');
    }
  }

  /// Check if current user's email is verified (reloads user first)
  @override
  Future<bool> checkEmailVerified() async {
    try {
      return await _authDatasource.checkEmailVerified();
    } catch (e) {
      AppLogger.error('AuthService', 'Error checking email verification: $e', e);
      return false;
    }
  }

  // MARK: - Account Deletion

  /// Reauthenticate the current user with their password.
  /// Returns failure with a stable code-derived message when Firebase rejects
  /// the credential (wrong password, requires-recent-login expired, etc.).
  @override
  Future<AuthResult> reauthenticateWithPassword({required String password}) async {
    final user = currentUser;
    if (user == null) {
      return AuthResult.failure('No user signed in');
    }
    final email = user.email;
    if (email == null || email.isEmpty) {
      return AuthResult.failure('Current user has no email on file');
    }

    try {
      AppLogger.debug('AuthService', 'Reauthenticating user: ${user.uid}');
      await _authDatasource.reauthenticateWithPassword(
        user: user,
        email: email,
        password: password,
      );
      AppLogger.info('AuthService', 'Reauthentication successful');
      return AuthResult.success(user);
    } on FirebaseAuthException catch (e) {
      AppLogger.error('AuthService', 'Reauthentication FirebaseAuthException: ${e.code} - ${e.message}', e);
      return AuthResult.failure(ErrorService.mapFirebaseAuthError(e));
    } catch (e) {
      AppLogger.error('AuthService', 'Unexpected reauthentication error: $e', e);
      return AuthResult.failure('Reauthentication failed: ${e.toString()}');
    }
  }

  /// Permanently delete the current Firebase Auth user and clear any local
  /// biometric credentials. Callers must perform Firestore + FCM cleanup
  /// while the user is still authenticated, then call this last.
  @override
  Future<AuthResult> deleteCurrentUser() async {
    final user = currentUser;
    if (user == null) {
      return AuthResult.failure('No user signed in');
    }

    try {
      AppLogger.debug('AuthService', 'Deleting Firebase Auth user: ${user.uid}');
      await _authDatasource.deleteUser(user);
      await _biometricDatasource.clearCredentials();
      AppLogger.info('AuthService', 'Account deletion successful');
      return AuthResult.success(null, message: 'Account deleted');
    } on FirebaseAuthException catch (e) {
      AppLogger.error('AuthService', 'Account deletion FirebaseAuthException: ${e.code} - ${e.message}', e);
      return AuthResult.failure(ErrorService.mapFirebaseAuthError(e));
    } catch (e) {
      AppLogger.error('AuthService', 'Unexpected account deletion error: $e', e);
      return AuthResult.failure('Account deletion failed: ${e.toString()}');
    }
  }
}

/// Authentication result wrapper
class AuthResult {
  final bool isSuccess;
  final User? user;
  final String? message;
  final String? error;

  AuthResult.success(this.user, {this.message})
    : isSuccess = true,
      error = null;

  AuthResult.failure(this.error)
    : isSuccess = false,
      user = null,
      message = null;
}

/// Bridge from [AuthResult] to [ServiceResult] for incremental migration.
/// Auth use cases can wrap their return values during Phase 3 migration.
extension AuthResultToServiceResult on AuthResult {
  ServiceResult<User> toServiceResult() {
    if (isSuccess && user != null) {
      return ServiceResult.success(user!);
    }
    return ServiceResult.failure(
      ServiceException.auth(error ?? 'Authentication failed'),
    );
  }
}
