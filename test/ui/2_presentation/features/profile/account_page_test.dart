// test/ui/2_presentation/features/profile/account_page_test.dart

import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:provider/provider.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/1_contracts/features/auth/i_auth_repository.dart';
import 'package:rivr/services/1_contracts/features/settings/i_settings_repository.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/services/4_infrastructure/shared/service_result.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_up_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_out_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/reset_password_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/enable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/disable_biometric_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/sign_in_with_biometrics_usecase.dart';
import 'package:rivr/models/2_usecases/features/auth/delete_account_usecase.dart';
import 'package:rivr/models/2_usecases/features/settings/sync_settings_after_login_usecase.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/2_presentation/features/profile/pages/account_page.dart';

// Minimal stubs — AuthProvider takes every collaborator as an injected
// optional, so we only need to satisfy the interfaces it touches. The
// deleteAccount happy/error paths themselves are covered by
// test/ui/1_state/features/auth/auth_provider_test.dart; this file guards
// the AccountPage wiring (structure + destructive-action UX).

class _StubAuthRepository implements IAuthRepository {
  String? capturedDeletePassword;
  bool deleteShouldSucceed = true;

  @override
  Future<ServiceResult<void>> deleteAccount({required String password}) async {
    capturedDeletePassword = password;
    return deleteShouldSucceed
        ? ServiceResult.success(null)
        : ServiceResult.failure(
            const ServiceException.auth('Invalid credentials'));
  }

  @override
  fb.User? get currentUser => null;
  @override
  Stream<fb.User?> get authStateChanges => const Stream.empty();
  @override
  Future<ServiceResult<void>> signOut() async => ServiceResult.success(null);
  @override
  Future<ServiceResult<fb.User?>> signIn({
    required String email,
    required String password,
  }) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<fb.User?>> signUp({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<void>> resetPassword({required String email}) async =>
      ServiceResult.success(null);
  @override
  Future<bool> isBiometricAvailable() async => false;
  @override
  Future<bool> isBiometricEnabled() async => false;
  @override
  Future<ServiceResult<fb.User?>> signInWithBiometrics() async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<void>> enableBiometric() async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<void>> disableBiometric() async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<UserSettings?>> syncSettingsAfterLogin(
          String userId) async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<void>> sendEmailVerification() async =>
      ServiceResult.success(null);
  @override
  Future<ServiceResult<bool>> checkEmailVerified() async =>
      ServiceResult.success(true);
}

class _StubSettingsRepository implements ISettingsRepository {
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _StubFcm implements IFCMService {
  @override
  void clearCache() {}
  @override
  noSuchMethod(Invocation invocation) => null;
}

AuthProvider _buildProvider(_StubAuthRepository repo) {
  final settingsRepo = _StubSettingsRepository();
  return AuthProvider(
    authRepository: repo,
    signInUseCase: SignInUseCase(repo),
    signUpUseCase: SignUpUseCase(repo),
    signOutUseCase: SignOutUseCase(repo),
    resetPasswordUseCase: ResetPasswordUseCase(repo),
    enableBiometricUseCase: EnableBiometricUseCase(repo),
    disableBiometricUseCase: DisableBiometricUseCase(repo),
    signInWithBiometricsUseCase: SignInWithBiometricsUseCase(repo),
    syncSettingsUseCase: SyncSettingsAfterLoginUseCase(settingsRepo),
    deleteAccountUseCase: DeleteAccountUseCase(repo),
    fcmService: _StubFcm(),
  );
}

Widget _wrap(AuthProvider provider) => ChangeNotifierProvider<AuthProvider>.value(
      value: provider,
      child: const CupertinoApp(home: AccountPage()),
    );

/// Wraps AccountPage as a *pushed* route on top of a root, mirroring how it
/// is presented in the app (Navigator.pushNamed from the three-dots menu on
/// top of the root AuthCoordinator). Needed to exercise post-sign-out
/// navigation, which pops back to the root.
Widget _wrapPushed(AuthProvider provider) =>
    ChangeNotifierProvider<AuthProvider>.value(
      value: provider,
      child: CupertinoApp(
        home: Builder(
          builder: (rootContext) => CupertinoPageScaffold(
            child: Center(
              child: CupertinoButton(
                child: const Text('ROOT'),
                onPressed: () => Navigator.of(rootContext).push(
                  CupertinoPageRoute<void>(
                    builder: (_) => const AccountPage(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  // Render the full page on a tall surface (no lazy ListView culling) so
  // off-screen rows like the bottom Delete Account are always in the tree.
  Future<void> pumpAccount(WidgetTester tester, _StubAuthRepository repo) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(_buildProvider(repo)));
  }

  testWidgets('shows only identity + the two account actions', (tester) async {
    final repo = _StubAuthRepository();
    await pumpAccount(tester, repo);

    expect(find.text('Account'), findsWidgets); // nav bar title
    expect(find.text('Sign Out'), findsOneWidget);
    expect(find.text('Delete Account'), findsOneWidget);

    // Preferences / notifications must NOT be duplicated here — they live
    // in the three-dots menu.
    expect(find.text('PREFERENCES'), findsNothing);
    expect(find.text('Flow unit'), findsNothing);
    expect(find.text('Notifications'), findsNothing);
    expect(find.text('DANGER ZONE'), findsNothing);
  });

  testWidgets('Delete Account is the last actionable row', (tester) async {
    final repo = _StubAuthRepository();
    await pumpAccount(tester, repo);

    final signOutY = tester.getCenter(find.text('Sign Out')).dy;
    final deleteY = tester.getCenter(find.text('Delete Account')).dy;
    expect(deleteY, greaterThan(signOutY),
        reason: 'Delete Account must sit below Sign Out (bottom of page)');
  });

  testWidgets('tapping Delete Account opens a password confirmation dialog',
      (tester) async {
    final repo = _StubAuthRepository();
    await pumpAccount(tester, repo);

    await tester.tap(find.text('Delete Account'));
    await tester.pumpAndSettle();

    // Confirmation dialog with a password field + destructive action.
    expect(find.byType(CupertinoTextField), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.widgetWithText(CupertinoDialogAction, 'Delete'),
        findsOneWidget);
  });

  testWidgets('confirming with a password forwards it to the use case',
      (tester) async {
    final repo = _StubAuthRepository();
    await pumpAccount(tester, repo);

    await tester.tap(find.text('Delete Account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(CupertinoTextField), 'hunter2');
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Delete'));
    await tester.pumpAndSettle();

    expect(repo.capturedDeletePassword, 'hunter2');
  });

  testWidgets('signing out pops the pushed Account route back to root',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repo = _StubAuthRepository();
    await tester.pumpWidget(_wrapPushed(_buildProvider(repo)));

    // Push the Account page on top of the root.
    await tester.tap(find.text('ROOT'));
    await tester.pumpAndSettle();
    expect(find.text('Sign Out'), findsOneWidget);
    expect(find.text('ROOT'), findsNothing); // Account now covers root

    // Sign out → confirm.
    await tester.tap(find.text('Sign Out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Sign Out'));
    await tester.pumpAndSettle();

    // Regression: the pushed Account route must be popped so the (now
    // logged-out) root is visible again — not left covering it.
    expect(find.text('Sign Out'), findsNothing);
    expect(find.text('ROOT'), findsOneWidget);
  });

  testWidgets('successful delete pops the pushed Account route back to root',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repo = _StubAuthRepository()..deleteShouldSucceed = true;
    await tester.pumpWidget(_wrapPushed(_buildProvider(repo)));

    await tester.tap(find.text('ROOT'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete Account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), 'pw');
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Account'), findsNothing);
    expect(find.text('ROOT'), findsOneWidget);
  });
}
