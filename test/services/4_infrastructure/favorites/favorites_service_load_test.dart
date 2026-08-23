// test/services/4_infrastructure/favorites/favorites_service_load_test.dart
//
// ADR 0011 Phase 2 (review round 8, F1 — a live bug): loadFavorites swallowed
// every exception to [], and since Phase 2 an empty favourites list is an
// ANSWER — it un-pins every reach in the retention cache and persists the
// empty pin set over pins.json. One Firestore hiccup at startup made every
// favourite evictable, on that launch and the next. The service must therefore
// only say "empty" when the account genuinely has no favourites.

import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/1_contracts/shared/i_auth_service.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/4_infrastructure/favorites/favorites_service.dart';

class _Auth implements IAuthService {
  _Auth({this.signedIn = true});
  final bool signedIn;

  @override
  fb.User? get currentUser =>
      signedIn ? MockUser(uid: 'u1', email: 'u@example.com') : null;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _ThrowingSettings implements IUserSettingsService {
  @override
  Future<UserSettings?> getUserSettings(String userId) async =>
      throw Exception('firestore unavailable');

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _EmptySettings implements IUserSettingsService {
  @override
  Future<UserSettings?> getUserSettings(String userId) async => null;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('a settings-load failure THROWS — it must not impersonate an empty '
      'account', () async {
    final svc = FavoritesService(
      settingsService: _ThrowingSettings(),
      authService: _Auth(),
    );

    await expectLater(svc.loadFavorites(), throwsA(isA<Exception>()),
        reason: 'swallowed to [], this answer un-pins every favourite and '
            'persists the empty set — could-not-load is not has-none');
  });

  test('a genuinely settings-less account IS empty, not an error', () async {
    final svc = FavoritesService(
      settingsService: _EmptySettings(),
      authService: _Auth(),
    );

    expect(await svc.loadFavorites(), isEmpty,
        reason: 'a new account has no settings doc yet; that is a real empty');
  });

  test('signed out IS empty, not an error', () async {
    final svc = FavoritesService(
      settingsService: _ThrowingSettings(), // must never even be called
      authService: _Auth(signedIn: false),
    );

    expect(await svc.loadFavorites(), isEmpty);
  });
}
