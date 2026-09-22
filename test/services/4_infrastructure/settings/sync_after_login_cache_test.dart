// test/services/4_infrastructure/settings/sync_after_login_cache_test.dart
//
// REGRESSION, build 832 (2026-09-22).
//
// `syncAfterLogin` READS settings and then WRITES them back with a fresh
// `lastLoginDate`. It read through an in-memory cache keyed on the uid — and
// ADR 0014's guest-to-account link KEEPS THE UID. So after linking, the cache
// still held the pre-link guest settings, and saving them back erased the
// email, the name and `isGuest: false` that registration had written moments
// earlier.
//
// The damage is not a stale screen. It is a stale DOCUMENT: the account was
// left looking like a guest, which `guestGcDaily` would eventually have been
// entitled to delete.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/1_contracts/shared/i_background_image_service.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/3_datasources/features/settings/settings_firestore_datasource.dart';
import 'package:rivr/services/4_infrastructure/settings/user_settings_service.dart';

class _StubUnits implements IFlowUnitPreferenceService {
  @override
  noSuchMethod(Invocation i) => null;
}

class _StubImages implements IBackgroundImageService {
  @override
  noSuchMethod(Invocation i) => null;
}

void main() {
  late FakeFirebaseFirestore db;
  late UserSettingsService service;

  const uid = 'same-uid-before-and-after-linking';

  UserSettings guestSettings() => UserSettings(
        userId: uid,
        email: '',
        firstName: '',
        lastName: '',
        preferredFlowUnit: FlowUnit.cfs,
        preferredTimeFormat: TimeFormat.twelveHour,
        enableNotifications: false,
        favoriteReachIds: const ['river-a'],
        lastLoginDate: DateTime(2026, 9, 22),
        createdAt: DateTime(2026, 9, 22),
        updatedAt: DateTime(2026, 9, 22),
        isGuest: true,
      );

  setUp(() {
    db = FakeFirebaseFirestore();
    service = UserSettingsService(
      datasource: SettingsFirestoreDatasource(firestore: db),
      unitService: _StubUnits(),
      imageService: _StubImages(),
    );
  });

  Future<Map<String, dynamic>?> doc() async =>
      (await db.collection('users').doc(uid).get()).data();

  test('syncAfterLogin does not write stale settings over a fresh link',
      () async {
    // 1. The guest session reads its settings, which fills the cache.
    await service.saveUserSettings(guestSettings());
    final cached = await service.getUserSettings(uid);
    expect(cached!.isGuest, isTrue);

    // 2. Registration links the credential and writes the identity straight
    //    to the document — the same thing AuthService._updateUserDoc does.
    await db.collection('users').doc(uid).set({
      'email': 'me@example.com',
      'firstName': 'Jerson',
      'lastName': 'Garcia',
      'isGuest': false,
    }, SetOptions(merge: true));

    // 3. The provider then syncs, which reads AND writes.
    await service.syncAfterLogin(uid);

    final after = await doc();
    expect(after!['email'], 'me@example.com',
        reason: 'the stale cached guest settings must not be written back');
    expect(after['firstName'], 'Jerson');
    expect(after['isGuest'], isFalse,
        reason: 'an account left marked isGuest is a candidate for '
            'guestGcDaily — this is how a real account gets deleted');
    expect(after['favoriteReachIds'], ['river-a'],
        reason: 'the rivers still have to survive the sync');
  });

  test('invalidateCache forces the next read to hit the datasource',
      () async {
    await service.saveUserSettings(guestSettings());
    await service.getUserSettings(uid);

    await db.collection('users').doc(uid).set(
        {'firstName': 'Changed'}, SetOptions(merge: true));

    expect((await service.getUserSettings(uid))!.firstName, '',
        reason: 'the cache is doing its job here');

    service.invalidateCache();
    expect((await service.getUserSettings(uid))!.firstName, 'Changed');
  });
}
