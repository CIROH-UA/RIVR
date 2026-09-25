import 'dart:async';
import 'package:flutter/widgets.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart' show MockUser;
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_up_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_out_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_anonymously_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/reset_password_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/enable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/disable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_with_biometrics_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/delete_account_usecase.dart';
import 'package:rivr/models/2_usecases/features/settings/sync_settings_after_login_usecase.dart';
import 'package:rivr/services/1_contracts/features/settings/i_settings_repository.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';

// ---------------------------------------------------------------------------
// Minimal mocks for AuthProvider unit tests
// ---------------------------------------------------------------------------

class _MockAuthRepository implements IAuthRepository {

  // ADR 0014 — guest mode.
  int signInAnonymouslyCalls = 0;
  int touchLastActiveCalls = 0;
  int markPromptCalls = 0;

  /// ADR 0014 UX-9 — guest sign-in can fail: offline on first launch, or the
  /// Anonymous provider switched off in the console.
  bool guestSignInFails = false;

  /// uids whose settings were actually written by the sign-in path.
  final List<String> createdSettingsFor = [];
  /// True when touchLastActive ran for a uid that had no settings yet — the
  /// ordering that created the stub.
  bool touchedBeforeSettings = false;

  @override
  Future<ServiceResult<fb.User?>> signInAnonymously() async {
    signInAnonymouslyCalls++;
    if (guestSignInFails) {
      return ServiceResult.failure(
          const ServiceException.auth('offline'));
    }
    simulateGuest();
    createdSettingsFor.add(_signedInUser!.uid);
    return ServiceResult.success(_signedInUser);
  }

  @override
  Future<void> touchLastActive(String userId) async {
    touchLastActiveCalls++;
    if (!createdSettingsFor.contains(userId)) touchedBeforeSettings = true;
  }

  @override
  Future<void> markAccountPromptShown(String userId) async {
    markPromptCalls++;
  }

  final StreamController<fb.User?> _authStateController =
      StreamController<fb.User?>.broadcast();

  MockUser? _signedInUser;
  bool _emailVerified = false;
  final Map<String, Map<String, String>> _accounts = {};

  void seedUser({
    required String email,
    required String password,
    bool emailVerified = true,
  }) {
    _accounts[email] = {'password': password};
    _emailVerified = emailVerified;
  }

  /// The stream emits null — a revoked token, a deleted account, or the
  /// stream's cold-start word for a signed-out app.
  void simulateAuthStateNull() {
    _signedInUser = null;
    _authStateController.add(null);
  }

  /// Mark the signed-in user verified, the way Firebase does once the link
  /// in the email is clicked. `checkEmailVerified` must pick this up.
  void simulateEmailVerified() {
    final u = _signedInUser;
    if (u == null) return;
    _emailVerified = true;
    _signedInUser = MockUser(
      uid: u.uid, email: u.email, displayName: u.displayName,
      isEmailVerified: true,
    );
  }

  /// ADR 0014 — a guest session: anonymous, no email, emailVerified false.
  void simulateGuest() {
    // isEmailVerified must be FALSE: firebase_auth_mocks defaults it to true,
    // but a real anonymous user's emailVerified is always false — and that is
    // the whole reason the verification gate had to learn about guests. A
    // guest fixture with emailVerified:true makes the gate tests vacuous.
    _signedInUser =
        MockUser(isAnonymous: true, isEmailVerified: false, uid: 'guest-uid');
    _authStateController.add(_signedInUser);
  }

  /// Simulate sign-in (used by the mock use case wrapper)
  void simulateSignIn(String email) {
    final account = _accounts[email];
    if (account == null) return;
    _signedInUser = MockUser(
      uid: 'uid-${email.hashCode}',
      email: email,
      displayName: 'Test User',
      isEmailVerified: _emailVerified,
    );
    _authStateController.add(_signedInUser);
  }

  @override
  fb.User? get currentUser => _signedInUser;

  @override
  Stream<fb.User?> get authStateChanges => _authStateController.stream;

  @override
  Future<ServiceResult<fb.User?>> signIn({
    required String email,
    required String password,
  }) async {
    final account = _accounts[email];
    if (account == null || account['password'] != password) {
      return ServiceResult.failure(
        const ServiceException.auth('Invalid email or password'),
      );
    }
    simulateSignIn(email);
    return ServiceResult.success(_signedInUser);
  }

  @override
  Future<ServiceResult<fb.User?>> signUp({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    if (_accounts.containsKey(email)) {
      return ServiceResult.failure(
        const ServiceException.auth('Email already in use'),
      );
    }
    _accounts[email] = {'password': password};
    _signedInUser = MockUser(
      uid: 'uid-${email.hashCode}',
      email: email,
      displayName: '$firstName $lastName',
      isEmailVerified: false,
    );
    _authStateController.add(_signedInUser);
    return ServiceResult.success(_signedInUser);
  }

  @override
  Future<ServiceResult<void>> signOut() async {
    _signedInUser = null;
    _authStateController.add(null);
    return ServiceResult.success(null);
  }

  @override
  Future<ServiceResult<void>> resetPassword({required String email}) async =>
      ServiceResult.success(null);

  @override
  Future<bool> isBiometricAvailable() async => false;
  @override
  Future<bool> isBiometricEnabled() async => false;

  @override
  Future<ServiceResult<fb.User?>> signInWithBiometrics() async =>
      ServiceResult.failure(const ServiceException.auth('N/A'));

  @override
  Future<ServiceResult<void>> enableBiometric() async =>
      ServiceResult.failure(const ServiceException.auth('N/A'));

  @override
  Future<ServiceResult<void>> disableBiometric() async =>
      ServiceResult.failure(const ServiceException.auth('N/A'));

  @override
  Future<ServiceResult<UserSettings?>> syncSettingsAfterLogin(
      String userId) async =>
      ServiceResult.success(null);

  @override
  Future<ServiceResult<void>> sendEmailVerification() async =>
      ServiceResult.success(null);

  @override
  Future<ServiceResult<bool>> checkEmailVerified() async =>
      ServiceResult.success(_emailVerified);

  @override
  Future<ServiceResult<void>> deleteAccount({required String? password}) async {
    if (_signedInUser == null) {
      return ServiceResult.failure(
        const ServiceException.auth('No user signed in'),
      );
    }
    final account = _accounts[_signedInUser!.email];
    if (account == null || account['password'] != password) {
      return ServiceResult.failure(
        const ServiceException.auth('Invalid credentials'),
      );
    }
    _accounts.remove(_signedInUser!.email);
    _signedInUser = null;
    _authStateController.add(null);
    return ServiceResult.success(null);
  }

  void dispose() => _authStateController.close();
}

class _MockSettingsRepository implements ISettingsRepository {
  /// Settings returned by [getUserSettings]. Null by default, which is what
  /// every pre-existing test wants; the notification-listener tests set it.
  UserSettings? settings;

  @override
  Future<ServiceResult<UserSettings?>> getUserSettings(String userId) async =>
      ServiceResult.success(settings);
  @override
  Future<ServiceResult<UserSettings?>> updateFlowUnit(
          String userId, FlowUnit flowUnit) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<UserSettings?>> updateNotifications(
          String userId, bool enableNotifications) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<UserSettings?>> updateNotificationFrequency(
          String userId, int frequency) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<UserSettings?>> syncAfterLogin(String userId) async =>
      ServiceResult.success(null);
}

class _MockFCMService implements IFCMService {
  @override
  set navigatorKey(GlobalKey<NavigatorState> key) {}
  @override
  Future<bool> initialize() async => true;
  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<NotificationPermissionResult> osPermissionStatus() async =>
      NotificationPermissionResult.granted;

  @override
  Future<NotificationPermissionResult> reconcileDevice(
    String userId, {
    required bool wantsAny,
  }) async =>
      NotificationPermissionResult.granted;

  int setupListenerCalls = 0;

  @override
  void setupNotificationListeners() => setupListenerCalls++;
  @override
  Future<NotificationPermissionResult> enableNotifications(
          String userId) async =>
      NotificationPermissionResult.granted;
  @override
  Future<void> disableNotifications(String userId) async {}
  @override
  Future<NotificationPermissionResult> enableWeeklyOutlook(
          String userId) async =>
      NotificationPermissionResult.granted;
  @override
  Future<void> disableWeeklyOutlook(String userId) async {}
  @override
  Future<bool> isEnabledForUser(String userId) async => false;
  @override
  Future<void> refreshTokenIfNeeded(String userId) async {}
  @override
  Future<void> unregisterDeviceToken(String userId) async {}
  @override
  void clearCache() {}
}

/// Records clear() calls — the wiring guard for ADR 0011 Phase 2. Round 2
/// proved the sign-out clear was deletable with the whole suite green: the
/// cache-side test proves clear() works, and nothing proved anyone calls it.
class _RecordingRiverDataCache implements IRiverDataCache {
  int clearCalls = 0;

  @override
  Future<void> clear() async => clearCalls++;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late _MockAuthRepository mockAuthRepo;
  late _MockSettingsRepository mockSettingsRepo;
  late _MockFCMService mockFcm;
  late AuthProvider provider;

  late _RecordingRiverDataCache riverCache;

  setUp(() {
    riverCache = _RecordingRiverDataCache();
    GetIt.I.registerSingleton<IRiverDataCache>(riverCache);
    mockAuthRepo = _MockAuthRepository();
    mockSettingsRepo = _MockSettingsRepository();
    mockFcm = _MockFCMService();
    provider = AuthProvider(
      authRepository: mockAuthRepo,
      signInUseCase: SignInUseCase(mockAuthRepo),
      signUpUseCase: SignUpUseCase(mockAuthRepo),
      signOutUseCase: SignOutUseCase(mockAuthRepo),
      signInAnonymouslyUseCase: SignInAnonymouslyUseCase(mockAuthRepo),
      resetPasswordUseCase: ResetPasswordUseCase(mockAuthRepo),
      enableBiometricUseCase: EnableBiometricUseCase(mockAuthRepo),
      disableBiometricUseCase: DisableBiometricUseCase(mockAuthRepo),
      signInWithBiometricsUseCase: SignInWithBiometricsUseCase(mockAuthRepo),
      syncSettingsUseCase: SyncSettingsAfterLoginUseCase(mockSettingsRepo),
      deleteAccountUseCase: DeleteAccountUseCase(mockAuthRepo),
      fcmService: mockFcm,
    );
  });

  tearDown(() {
    provider.dispose();
    mockAuthRepo.dispose();
    GetIt.I.reset();
  });

  group('AuthProvider', () {
    group('clearMessages', () {
      test('clears error message', () {
        // Trigger an error by signing in with empty fields
        provider.signIn('', 'password');

        expect(provider.errorMessage, isNotEmpty);

        provider.clearMessages();

        expect(provider.errorMessage, isEmpty);
        expect(provider.successMessage, isEmpty);
      });

      test('clears success message', () async {
        mockAuthRepo.seedUser(
            email: 'test@example.com',
            password: 'pass123',
            emailVerified: true);

        // sendPasswordReset sets a success message
        await provider.sendPasswordReset('test@example.com');
        expect(provider.successMessage, isNotEmpty);

        provider.clearMessages();

        expect(provider.successMessage, isEmpty);
        expect(provider.errorMessage, isEmpty);
      });
    });

    group('signIn', () {
      test('does not set success message on successful sign-in', () async {
        mockAuthRepo.seedUser(
            email: 'user@example.com',
            password: 'pass123',
            emailVerified: true);

        final result =
            await provider.signIn('user@example.com', 'pass123');

        expect(result, isTrue);
        expect(provider.successMessage, isEmpty);
        expect(provider.errorMessage, isEmpty);
      });

      test('sets error message on failed sign-in', () async {
        mockAuthRepo.seedUser(
            email: 'user@example.com', password: 'correct');

        final result =
            await provider.signIn('user@example.com', 'wrong');

        expect(result, isFalse);
        expect(provider.errorMessage, 'Invalid email or password');
        expect(provider.successMessage, isEmpty);
      });

      test('sets error for empty email', () async {
        final result = await provider.signIn('', 'password');

        expect(result, isFalse);
        expect(provider.errorMessage,
            'Please enter both email and password');
      });
    });

    group('register', () {
      test(
          'confirms, and does not strand the user on a verification wall',
          () async {
        // Before ADR 0014 this asserted the opposite: no message, and
        // isAwaitingEmailVerification true, because registration ENDED at
        // EmailVerificationPage. Registration now happens inside the app
        // (usually by linking a guest), so the user stays where they were
        // and needs telling that it worked. The unverified state is still
        // recorded — it drives the Account page banner — it just no longer
        // gates anything.
        final result = await provider.register(
          email: 'new@example.com',
          password: 'pass123',
          firstName: 'Jane',
          lastName: 'Doe',
        );

        expect(result, isTrue);
        expect(provider.successMessage, isNotEmpty);
      });

      test('sets error message on failed registration', () async {
        // Seed an existing account so registration fails
        mockAuthRepo.seedUser(
            email: 'taken@example.com', password: 'pass');

        final result = await provider.register(
          email: 'taken@example.com',
          password: 'pass123',
          firstName: 'Jane',
          lastName: 'Doe',
        );

        expect(result, isFalse);
        expect(provider.errorMessage, 'Email already in use');
        expect(provider.successMessage, isEmpty);
      });

      test('sets error for empty fields', () async {
        final result = await provider.register(
          email: '',
          password: 'pass123',
          firstName: 'Jane',
          lastName: 'Doe',
        );

        expect(result, isFalse);
        expect(provider.errorMessage,
            'Please fill in all required fields');
      });
    });

    group('sendPasswordReset', () {
      test('sets success message on success', () async {
        final result =
            await provider.sendPasswordReset('user@example.com');

        expect(result, isTrue);
        expect(provider.successMessage, 'Password reset email sent');
        expect(provider.errorMessage, isEmpty);
      });
    });

    // ADR 0011 Phase 2: every identity change drops the river-data cache and
    // its pins — carried over, the pins shield the previous user's favourites
    // from the next user's retention cap. Round 2 found the fix on signOut
    // alone (deleteAccount's own "mirror signOut's cleanup" comment promising
    // a mirror it did not perform), and the wiring entirely unguarded.
    group('identity changes clear the river-data cache', () {
      test('signOut clears it', () async {
        await provider.signOut();

        expect(riverCache.clearCalls, greaterThan(0),
            reason: 'the cache-side tests prove clear() works; this proves '
                'someone calls it');
      });

      test('deleteAccount clears it', () async {
        mockAuthRepo.seedUser(
          email: 'doomed@example.com',
          password: 'correct-pass',
        );
        mockAuthRepo.simulateSignIn('doomed@example.com');
        riverCache.clearCalls = 0; // ignore any sign-in-time activity

        await provider.deleteAccount('correct-pass');

        expect(riverCache.clearCalls, greaterThan(0),
            reason: 'account deletion is the strongest identity change there '
                'is — pins surviving it belong to a user who no longer exists');
      });

      test('a failed deleteAccount clears nothing', () async {
        mockAuthRepo.seedUser(
          email: 'safe@example.com',
          password: 'correct-pass',
        );
        mockAuthRepo.simulateSignIn('safe@example.com');
        riverCache.clearCalls = 0;

        await provider.deleteAccount('wrong-password');

        expect(riverCache.clearCalls, 0,
            reason: 'the account is still there; its cache is still its own');
      });
    });

    // REGRESSION (round 3, F1): the auth-state listener's clear — the path a
    // revoked token or a server-side account removal takes — was deletable
    // with the suite green, because no test ever called initialize() and
    // subscribed the listener. And the clear must be gated on a null that
    // FOLLOWS a non-null: the stream emits null on a signed-out cold start,
    // and clearing there wipes pins on every launch — undoing the cold-start
    // eviction fix outright.
    group('the auth-state listener', () {
      test('a server-side sign-out clears the cache', () async {
        mockAuthRepo.seedUser(
            email: 'revoked@example.com', password: 'pw');
        await provider.initialize();
        mockAuthRepo.simulateSignIn('revoked@example.com');
        await Future<void>.delayed(Duration.zero);
        riverCache.clearCalls = 0;

        // The token is revoked remotely: the stream emits null.
        mockAuthRepo.simulateAuthStateNull();
        await Future<void>.delayed(Duration.zero);

        expect(riverCache.clearCalls, greaterThan(0),
            reason: 'the remote sign-out path must clear the same caches the '
                'explicit signOut() does');
      });

      test('a cold start with no session at all clears nothing', () async {
        // ADR 0014 changed the premise: the app now signs in as a guest on
        // launch, so "signed out at launch" only happens when guest sign-in
        // itself fails (offline, or the provider switched off). The guard is
        // the same one — a null that follows NO user is a cold start, not a
        // sign-out, and clearing here wipes the pins file on every launch.
        mockAuthRepo.guestSignInFails = true;

        await provider.initialize();
        mockAuthRepo.simulateAuthStateNull();
        await Future<void>.delayed(Duration.zero);

        expect(provider.guestSignInError, isNotNull);
        expect(riverCache.clearCalls, 0);
      });
    });

    group('deleteAccount', () {
      test('returns true and sets success message on correct password',
          () async {
        mockAuthRepo.seedUser(
          email: 'doomed@example.com',
          password: 'correct-pass',
        );
        mockAuthRepo.simulateSignIn('doomed@example.com');

        final result = await provider.deleteAccount('correct-pass');

        expect(result, isTrue);
        expect(provider.successMessage, 'Account deleted');
        expect(provider.errorMessage, isEmpty);
      });

      test('returns false and sets error message on wrong password',
          () async {
        mockAuthRepo.seedUser(
          email: 'doomed@example.com',
          password: 'correct-pass',
        );
        mockAuthRepo.simulateSignIn('doomed@example.com');

        final result = await provider.deleteAccount('wrong-pass');

        expect(result, isFalse);
        expect(provider.errorMessage, 'Invalid credentials');
        expect(provider.successMessage, isEmpty);
      });

      test('fails fast on empty password without hitting the repository',
          () async {
        final result = await provider.deleteAccount('');

        expect(result, isFalse);
        expect(provider.errorMessage,
            'Please enter your password to confirm account deletion');
      });
    });
  });
  // ── ADR 0008 defect, carried into ADR 0011's Phase 9 list ────────────────
  //
  // The gate was `enableNotifications` alone. The Weekly Outlook shipped with
  // its OWN toggle, so a user can have flood alerts off and the weekly digest
  // on — and that user still receives a notification every Friday. With no
  // listeners registered, tapping it opened the app wherever it was last
  // instead of routing to the digest, and their token was never refreshed, so
  // the weekly could eventually stop arriving at all.
  //
  // Tested through the pure decision rather than the provider: reaching the
  // gate through `refreshUserSettings` needs a signed-in user, a sync use case
  // and a settings repository, which is exactly the plumbing that left this
  // branch untested for as long as it was wrong.
  group('wantsAnyNotification — who needs listeners', () {
    UserSettings settings({required bool alerts, required bool weekly}) =>
        UserSettings(
          userId: 'u1',
          email: 'u@example.com',
          firstName: 'U',
          lastName: 'Ser',
          preferredFlowUnit: FlowUnit.cfs,
          preferredTimeFormat: TimeFormat.twelveHour,
          enableNotifications: alerts,
          weeklyOutlookEnabled: weekly,
          favoriteReachIds: const [],
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
          lastLoginDate: DateTime.utc(2026, 1, 1),
        );

    test('alerts on, weekly off', () {
      expect(wantsAnyNotification(settings(alerts: true, weekly: false)),
          isTrue);
    });

    // THE regression. False before the fix.
    test('alerts OFF, weekly ON — still needs listeners', () {
      expect(
        wantsAnyNotification(settings(alerts: false, weekly: true)),
        isTrue,
        reason: 'a weekly-only user gets a notification every Friday; without '
            'listeners the tap does not route and their token is never '
            'refreshed',
      );
    });

    test('both on', () {
      expect(wantsAnyNotification(settings(alerts: true, weekly: true)),
          isTrue);
    });

    // The other direction must still hold: someone who wants nothing should
    // not have listeners registered or a token refreshed on their behalf.
    test('both off — no listeners', () {
      expect(wantsAnyNotification(settings(alerts: false, weekly: false)),
          isFalse);
    });

    test('no settings at all — no listeners', () {
      expect(wantsAnyNotification(null), isFalse);
    });
  });

  // The call site must actually use the decision; a pure function nothing
  // calls is the wiring gap this project keeps rediscovering.
  test('the provider gates listener setup on wantsAnyNotification', () {
    final src = File('lib/ui/1_state/features/auth/auth_provider.dart')
        .readAsStringSync();
    expect(src.contains('if (wantsAnyNotification(_currentUserSettings))'),
        isTrue,
        reason: 'the gate was inlined again, so the decision above no longer '
            'describes what the app does');
  });


  // ── ADR 0014 guest mode ────────────────────────────────────────────────────

  group('guest mode', () {
    test('a guest is never held at the verification wall', () async {
      // An anonymous user's emailVerified is ALWAYS false. Before ADR 0014
      // the gate keyed on that alone, so every guest would have been dumped
      // on EmailVerificationPage with no way past — the 5.1.1(v) rejection
      // again, with extra steps.
      mockAuthRepo.simulateGuest();

      await provider.initialize();
      await Future.delayed(Duration.zero);

      expect(provider.isGuest, isTrue);
      expect(provider.isAwaitingEmailVerification, isFalse);
      expect(provider.needsEmailVerification, isFalse,
          reason: 'a guest has no email to verify');
      expect(provider.isAuthenticated, isTrue,
          reason: 'the app opens for a guest like any other user');
    });

    test('a guest arriving on the auth stream is not gated either', () async {
      // Two code paths set this flag — the initial read in initialize() and
      // the authStateChanges listener. A guest reaches the second one when
      // the session is created AFTER startup (the UX-9 retry, or a deleted
      // guest being replaced). Mutating either must fail a test.
      await provider.initialize();
      await Future.delayed(Duration.zero);

      mockAuthRepo.simulateGuest();
      await Future.delayed(Duration.zero);

      expect(provider.isGuest, isTrue);
      expect(provider.isAwaitingEmailVerification, isFalse);
    });

    test('an unverified ACCOUNT is recorded but not gated', () async {
      mockAuthRepo.seedUser(
          email: 'a@b.com', password: 'pw', emailVerified: false);
      mockAuthRepo.simulateSignIn('a@b.com');

      await provider.initialize();
      await Future.delayed(Duration.zero);

      expect(provider.isGuest, isFalse);
      expect(provider.needsEmailVerification, isTrue,
          reason: 'the Account page shows a banner for this');
    });

    test('no session at all opens one as a guest', () async {
      expect(mockAuthRepo.currentUser, isNull);

      await provider.initialize();
      await Future.delayed(Duration.zero);

      expect(mockAuthRepo.signInAnonymouslyCalls, 1,
          reason: 'UX-1: launch goes to the app, not to a login wall');
      expect(provider.isGuest, isTrue);
    });


    test('startup leaves a COMPLETE guest document, not a stub', () async {
      // The defect class my other guest tests could not see: they all called
      // AuthService.signInAnonymously() directly, so they never exercised the
      // real startup ORDER. In the app, the auth-state listener fires the
      // instant the anonymous user exists and writes lastActiveAt — which,
      // with set-merge, created the document first and made signInAnonymously
      // skip writing the real settings. Every guest in build 838 got a stub
      // and could not save a single favourite.
      //
      // So this drives initialize() and then asserts on the DOCUMENT, not on
      // the call.
      await provider.initialize();
      await Future.delayed(Duration.zero);

      expect(provider.isGuest, isTrue);
      expect(mockAuthRepo.createdSettingsFor, isNotEmpty,
          reason: 'startup must write real settings for a new guest');
      expect(mockAuthRepo.touchedBeforeSettings, isFalse,
          reason: 'a sign-of-life write must never be the thing that '
              'creates the document');
    });

    test('an existing account is never replaced by a guest', () async {
      mockAuthRepo.seedUser(email: 'a@b.com', password: 'pw');
      mockAuthRepo.simulateSignIn('a@b.com');

      await provider.initialize();
      await Future.delayed(Duration.zero);

      expect(mockAuthRepo.signInAnonymouslyCalls, 0);
      expect(provider.isGuest, isFalse);
    });

    test('a sign of life is recorded for the garbage collector', () async {
      mockAuthRepo.simulateGuest();

      await provider.initialize();
      await Future.delayed(Duration.zero);

      expect(mockAuthRepo.touchLastActiveCalls, greaterThan(0),
          reason: 'guestGcDaily reaps guests on lastActiveAt alone');
    });


    test('verifying clears the banner, not just the flag', () async {
      // REGRESSION, build 832 (2026-09-22): "I tapped 'I've verified it' and
      // nothing happened." Firebase HAD the address verified; the Account
      // page's banner reads `needsEmailVerification`, which reads the CACHED
      // AuthUser — and checkEmailVerified only cleared a separate flag, never
      // refreshing the cached identity. The button looked dead.
      mockAuthRepo.seedUser(
          email: 'a@b.com', password: 'pw', emailVerified: false);
      mockAuthRepo.simulateSignIn('a@b.com');
      await provider.initialize();
      await Future.delayed(Duration.zero);
      expect(provider.needsEmailVerification, isTrue);

      mockAuthRepo.simulateEmailVerified();
      final ok = await provider.checkEmailVerified();

      expect(ok, isTrue);
      expect(provider.needsEmailVerification, isFalse,
          reason: 'this is what the banner actually reads');
    });

    test('signing out a guest is refused, not performed', () async {
      mockAuthRepo.simulateGuest();
      await provider.initialize();
      await Future.delayed(Duration.zero);

      await provider.signOut();

      expect(provider.isGuest, isTrue,
          reason: 'an anonymous uid signed out can never be recovered');
      expect(provider.errorMessage, isNotEmpty);
    });
  });
}
