// PHASE 2 BASELINE — MUST FAIL against HEAD b2aa2ac.
//
// Defect #2 (audit A1). Two facts combine:
//
//   1. `SettingsFirestoreDatasource.saveSettings`
//      (lib/services/3_datasources/features/settings/settings_firestore_datasource.dart:38)
//      is `.set(dto.toJson())` with NO merge — a whole-document overwrite.
//   2. `UserSettingsService._cachedSettings`
//      (lib/services/4_infrastructure/settings/user_settings_service.dart:30-31)
//      has no TTL and is cleared ONLY by a write through that same service on
//      that same device, by sign-out, or by `syncAfterLogin`. Nothing clears
//      it when a Cloud Function or the user's other phone writes.
//
// So `updateFlowUnit` (:390-400) — the ft3/s <-> m3/s toggle at
// favorites_page.dart:880 — does getUserSettings (served from the stale
// cache) -> copyWith -> saveUserSettings (whole-document set), reverting
// everything written since the cached read.
//
// Three of those reverts are user-visible:
//   * a river added on another device disappears;
//   * an FCM token the server pruned (notification-service.ts) comes back, so
//     every flood alert keeps failing to deliver;
//   * `weeklyDigestsSinceOpen` resets, restarting the digest back-off.
//
// `updateNotifications` (:420) and `updateRiverAlertFrequency` (:472) already
// use the partial-update path and their comments state this exact hazard.
// Seven sibling methods do not.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/1_contracts/shared/i_background_image_service.dart';
import 'package:rivr/services/3_datasources/features/settings/settings_firestore_datasource.dart';
import 'package:rivr/services/4_infrastructure/media/background_image_service.dart';
import 'package:rivr/services/4_infrastructure/settings/user_settings_service.dart';
import 'package:rivr/services/4_infrastructure/shared/flow_unit_preference_service.dart';

class _NoImages implements IBackgroundImageService {
  @override
  Future<bool> imageExists(String imagePath) async => true;
  @override
  Future<bool> deleteCustomBackground(String imagePath) async => true;
  @override
  Future<void> cleanupOldBackgrounds(String userId) async {}
  @override
  Future<BackgroundImageResult> pickFromGallery(String userId) =>
      throw UnimplementedError();
  @override
  Future<BackgroundImageResult> pickFromCamera(String userId) =>
      throw UnimplementedError();
  @override
  Future<BackgroundImageResult> showImageSourceSelector({
    required BuildContext context,
    required String userId,
  }) =>
      throw UnimplementedError();
}

void main() {
  const uid = 'account-uid';

  /// Launch-read, three writers this device knows nothing about, then the
  /// user taps the flow-unit toggle and nothing else.
  Future<Map<String, dynamic>> afterUnitToggle(FakeFirebaseFirestore db) async {
    final service = UserSettingsService(
      datasource: SettingsFirestoreDatasource(firestore: db),
      unitService: FlowUnitPreferenceService(),
      imageService: _NoImages(),
    );
    // 1. The app reads once at launch; this populates the in-memory cache,
    //    which has no TTL and which no server write invalidates.
    expect(await service.getUserSettings(uid), isNotNull);

    // 2. The user's other phone adds a river; notification-service.ts prunes
    //    the dead FCM token and records the live one; weekly-digest.ts
    //    increments the digest counter.
    final d = db.collection('users').doc(uid);
    await d.update({'favoriteReachIds': ['10376605', '23021904']});
    await d.update({'fcmTokens': ['live-token-from-this-install']});
    await d.update({'weeklyDigestsSinceOpen': 4});

    // 3. The user taps ft3/s -> m3/s.
    await service.updateFlowUnit(uid, FlowUnit.cms);

    final after = (await d.get()).data()!;
    // ignore: avoid_print
    print('after the toggle: favoriteReachIds=${after['favoriteReachIds']} '
        'fcmTokens=${after['fcmTokens']} '
        'weeklyDigestsSinceOpen=${after['weeklyDigestsSinceOpen']} '
        'preferredFlowUnit=${after['preferredFlowUnit']}');
    return after;
  }

  Future<FakeFirebaseFirestore> seeded() async {
    final db = FakeFirebaseFirestore();
    await db.collection('users').doc(uid).set({
      'userId': uid,
      'email': 'jerson@example.com',
      'preferredFlowUnit': 'cfs',
      'favoriteReachIds': ['10376605'],
      'fcmTokens': ['dead-token-the-server-will-prune'],
      'weeklyDigestsSinceOpen': 3,
      'enableNotifications': true,
    });
    return db;
  }

  test('the toggle itself still works (control)', () async {
    final after = await afterUnitToggle(await seeded());
    expect(after['preferredFlowUnit'], 'cms');
  });

  test('a unit toggle must not drop a river added on another device',
      () async {
    final after = await afterUnitToggle(await seeded());
    expect(after['favoriteReachIds'], ['10376605', '23021904']);
  });

  test('a unit toggle must not resurrect an FCM token the server pruned '
      '(every flood alert then keeps failing to deliver)', () async {
    final after = await afterUnitToggle(await seeded());
    expect(after['fcmTokens'], ['live-token-from-this-install']);
  });

  test('a unit toggle must not rewind a server-owned counter', () async {
    final after = await afterUnitToggle(await seeded());
    expect(after['weeklyDigestsSinceOpen'], 4);
  });

  test('a whole-document write must not delete fields the Dart DTO does not '
      'model (cross-language schema contract, no drift test exists)', () async {
    final db = FakeFirebaseFirestore();
    const uid = 'account-uid';

    await db.collection('users').doc(uid).set({
      'userId': uid,
      'email': 'jerson@example.com',
      'preferredFlowUnit': 'cfs',
      // A field a future Cloud Function adds, that UserSettingsDto has not
      // been taught about yet.
      'someServerOwnedField': 'matters-to-the-server',
    });

    final service = UserSettingsService(
      datasource: SettingsFirestoreDatasource(firestore: db),
      unitService: FlowUnitPreferenceService(),
      imageService: _NoImages(),
    );

    final s = await service.getUserSettings(uid);
    await service.saveUserSettings(s!);

    final after = (await db.collection('users').doc(uid).get()).data()!;

    // ---- FAILS today ----
    expect(after.containsKey('someServerOwnedField'), isTrue,
        reason: 'a client round trip must not silently delete a field the '
            'server owns');
  });
  // ───────────────────────────────────────────────────────────────────────
  // The race the fresh read does NOT close.
  //
  // Added 2026-11-09 after a mutation run: removing the server-owned-field
  // stripping from `saveSettings` left every test above green, because a
  // fresh read hands the client the server's current values and writing
  // them back unchanged is harmless.
  //
  // It stops being harmless the moment the server writes BETWEEN this
  // client's read and its write. Then the client's "current" values are
  // already a generation old, and writing them back reverts the server —
  // resurrecting a pruned push token, which is the one that silently kills
  // every flood alert to that device.
  //
  // A guard that only passes because of a different mechanism is not a
  // guard. This one fails if the stripping is removed.
  // ───────────────────────────────────────────────────────────────────────
  test('a server write landing mid-save must not be reverted', () async {
    final db = FakeFirebaseFirestore();
    final svc = UserSettingsService(
      datasource: SettingsFirestoreDatasource(firestore: db),
      unitService: FlowUnitPreferenceService(),
      imageService: _NoImages(),
    );

    await db.collection('users').doc(uid).set({
      'userId': uid,
      'email': 'a@b.c',
      'firstName': 'A',
      'lastName': 'B',
      'preferredFlowUnit': 'cfs',
      'fcmTokens': ['live-token-from-this-install', 'token-the-server-kills'],
      'favoriteReachIds': <String>[],
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-01T00:00:00.000Z',
      'lastLoginDate': '2026-01-01T00:00:00.000Z',
    });

    // The client reads. Its in-hand copy still has both tokens.
    final base = await svc.getUserSettings(uid, forceRefresh: true);
    expect(base, isNotNull);

    // The server prunes the dead token — AFTER the read, BEFORE the write.
    // This is notification-service.ts reacting to an APNs rejection.
    await db.collection('users').doc(uid).set(
      {'fcmTokens': ['live-token-from-this-install']},
      SetOptions(merge: true),
    );

    // The client now saves its settings change.
    await svc.saveUserSettings(base!.copyWith(preferredFlowUnit: FlowUnit.cms));

    final after = (await db.collection('users').doc(uid).get()).data()!;
    expect(after['preferredFlowUnit'], 'cms',
        reason: 'the change the user actually made must land');
    expect(after['fcmTokens'], ['live-token-from-this-install'],
        reason: 'the dead token must stay dead. A client that writes back a '
            'token list it read moments ago resurrects whatever the server '
            'pruned in between, and every flood alert to that device then '
            'fails to deliver, silently and forever');
  });

}
