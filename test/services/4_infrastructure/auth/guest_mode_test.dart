// test/services/4_infrastructure/auth/guest_mode_test.dart
//
// ADR 0014 guest mode — the service-level guards.
//
// These exist because the App Store rejected 2026.2.2 (805) under 5.1.1(v)
// for requiring registration before the map, and the fix moves identity
// underneath everything the app already does. The risky part is not "can a
// guest sign in" — it is the two transitions:
//
//   * a guest CREATING an account, which must keep the uid (link, not
//     create) or every favourite, alert setting and custom name is silently
//     abandoned; and
//   * a guest SIGNING IN to an account they already have, where two
//     documents exist and the rivers have to end up in the right one while
//     the abandoned one stops driving the store and the alert queries.
//
// Every test below is mutation-checked: reverting the behaviour under test
// fails it.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
// MockUserCredential is not exported from the package root.
import 'package:firebase_auth_mocks/src/mock_user_credential.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/3_datasources/features/auth/auth_firebase_datasource.dart';
import 'package:rivr/services/4_infrastructure/auth/auth_service.dart';

/// A datasource whose Firebase calls are scripted. `AuthFirebaseDatasource`
/// is concrete and its calls hit the real SDK, so the fake overrides the four
/// methods guest mode uses and records what it was asked to do.
class _FakeDatasource extends AuthFirebaseDatasource {
  _FakeDatasource() : super(firebaseAuth: MockFirebaseAuth());

  fb.User? user;
  bool linkThrows = false;
  bool signInThrows = false;
  int registerCalls = 0;
  int linkCalls = 0;
  final List<String> deletedUids = [];

  @override
  fb.User? get currentUser => user;

  @override
  Future<fb.UserCredential> signInAnonymously() async {
    user = MockUser(
        isAnonymous: true, isEmailVerified: false, uid: 'guest-uid');
    return MockUserCredential(true, mockUser: user as MockUser);
  }

  @override
  Future<fb.UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    if (signInThrows) {
      throw fb.FirebaseAuthException(code: 'wrong-password');
    }
    user = MockUser(uid: 'account-uid', email: email);
    return MockUserCredential(false, mockUser: user as MockUser);
  }

  @override
  Future<fb.UserCredential> register({
    required String email,
    required String password,
  }) async {
    registerCalls++;
    user = MockUser(uid: 'brand-new-uid', email: email);
    return MockUserCredential(false, mockUser: user as MockUser);
  }

  @override
  Future<fb.UserCredential> linkWithEmailPassword({
    required fb.User user,
    required String email,
    required String password,
  }) async {
    linkCalls++;
    if (linkThrows) {
      throw fb.FirebaseAuthException(code: 'email-already-in-use');
    }
    // Firebase keeps the uid and adds the credential.
    final linked = MockUser(uid: user.uid, email: email);
    this.user = linked;
    return MockUserCredential(false, mockUser: linked);
  }

  @override
  Future<void> updateDisplayName(fb.User user, String displayName) async {}

  @override
  Future<void> sendEmailVerification(fb.User user) async {}

  @override
  Future<void> deleteUser(fb.User user) async {
    deletedUids.add(user.uid);
    this.user = null;
  }
}

void main() {
  late _FakeDatasource ds;
  late FakeFirebaseFirestore db;
  late AuthService service;

  setUp(() {
    ds = _FakeDatasource();
    db = FakeFirebaseFirestore();
    service = AuthService(authDatasource: ds, firestore: db);
  });

  Future<Map<String, dynamic>?> doc(String uid) async =>
      (await db.collection('users').doc(uid).get()).data();

  group('a guest arrives', () {
    test('signing in as a guest creates the document the app needs', () async {
      // ADR 0014 M5: register was the ONLY path that ever wrote this
      // document. Without it, a guest has no defaults, no notification flags
      // and nothing for the Cloud Functions to read.
      final result = await service.signInAnonymously();

      expect(result.isSuccess, isTrue);
      final d = await doc('guest-uid');
      expect(d, isNotNull);
      expect(d!['isGuest'], isTrue);
      expect(d['favoriteReachIds'], isEmpty);
      expect(d['enableNotifications'], isFalse);
      expect(d['email'], '');
      expect(d['lastActiveAt'], isNotNull);
    });

    test('it is idempotent — an existing session is returned untouched',
        () async {
      ds.user = MockUser(uid: 'account-uid', email: 'a@b.com');

      final result = await service.signInAnonymously();

      expect(result.isSuccess, isTrue);
      expect(result.user?.uid, 'account-uid');
      // No guest document was minted for an account that was already signed in.
      expect(await doc('guest-uid'), isNull);
    });

    test('a sign of life is recorded for the garbage collector', () async {
      await service.signInAnonymously();
      await db.collection('users').doc('guest-uid').update({
        'lastActiveAt': '2020-01-01T00:00:00.000Z',
      });

      await service.touchLastActive('guest-uid');

      final stamp = DateTime.parse((await doc('guest-uid'))!['lastActiveAt']);
      expect(stamp.isAfter(DateTime(2021)), isTrue,
          reason: 'guestGcDaily reaps on this field alone');
    });
  });

  group('a guest creates an account', () {
    setUp(() async {
      await service.signInAnonymously();
      await db.collection('users').doc('guest-uid').update({
        'favoriteReachIds': ['river-a'],
        'favoriteLabels': {'river-a': 'My creek'},
      });
    });

    test('links in place: same uid, same document, rivers intact', () async {
      final result = await service.registerWithEmailAndPassword(
        email: 'me@example.com',
        password: 'hunter2',
        firstName: 'Jerson',
        lastName: 'Garcia',
      );

      expect(result.isSuccess, isTrue);
      expect(ds.linkCalls, 1);
      expect(ds.registerCalls, 0,
          reason: 'createUserWithEmailAndPassword would mint a NEW uid and '
              'strand every favourite the guest saved');
      expect(result.user?.uid, 'guest-uid');

      final d = await doc('guest-uid');
      expect(d!['favoriteReachIds'], ['river-a']);
      expect(d['favoriteLabels'], {'river-a': 'My creek'});
      expect(d['isGuest'], isFalse);
      expect(d['email'], 'me@example.com');
      expect(d['firstName'], 'Jerson');
    });

    test('a link failure leaves the guest exactly as they were', () async {
      ds.linkThrows = true;

      final result = await service.registerWithEmailAndPassword(
        email: 'taken@example.com',
        password: 'hunter2',
        firstName: 'A',
        lastName: 'B',
      );

      expect(result.isSuccess, isFalse);
      final d = await doc('guest-uid');
      expect(d!['isGuest'], isTrue);
      expect(d['favoriteReachIds'], ['river-a']);
    });

    test('with no session at all it still creates a normal account', () async {
      // UX-9: guest sign-in can fail (offline first launch). Registration
      // must not depend on a guest existing.
      ds.user = null;

      final result = await service.registerWithEmailAndPassword(
        email: 'fresh@example.com',
        password: 'hunter2',
        firstName: 'A',
        lastName: 'B',
      );

      expect(result.isSuccess, isTrue);
      expect(ds.registerCalls, 1);
      expect(ds.linkCalls, 0);
      final d = await doc('brand-new-uid');
      expect(d!['isGuest'], isFalse);
    });
  });

  group('a guest signs in to an account they already have', () {
    setUp(() async {
      await service.signInAnonymously();
      await db.collection('users').doc('guest-uid').update({
        'favoriteReachIds': ['river-a', 'river-shared'],
        'favoriteSources': {'river-a': 'nwm', 'river-shared': 'nwm'},
        'favoriteLabels': {'river-shared': 'guest name'},
        'fcmTokens': ['token-1'],
        'enableNotifications': true,
      });
      await db.collection('users').doc('account-uid').set({
        'userId': 'account-uid',
        'email': 'me@example.com',
        'firstName': 'Jerson',
        'lastName': 'Garcia',
        'isGuest': false,
        'favoriteReachIds': ['river-shared', 'river-c'],
        'favoriteSources': {'river-shared': 'nwm', 'river-c': 'geoglows'},
        'favoriteLabels': {'river-shared': 'account name'},
        'favoriteReachIdsNote': 'unused',
      });
    });

    test('the rivers move across and the account wins every conflict',
        () async {
      final result = await service.signInWithEmailAndPassword(
        email: 'me@example.com',
        password: 'hunter2',
      );

      expect(result.isSuccess, isTrue);
      final account = await doc('account-uid');
      expect(
        (account!['favoriteReachIds'] as List).toSet(),
        {'river-shared', 'river-c', 'river-a'},
      );
      expect((account['favoriteLabels'] as Map)['river-shared'], 'account name',
          reason: 'a name chosen on the account beats one typed as a guest');
      expect((account['favoriteSources'] as Map)['river-a'], 'nwm');
    });

    test('the abandoned guest stops driving alerts and the store', () async {
      await service.signInWithEmailAndPassword(
        email: 'me@example.com',
        password: 'hunter2',
      );

      // Deleted outright is the happy path; if the Auth delete fails the
      // document must at least be inert.
      final leftover = await doc('guest-uid');
      if (leftover != null) {
        expect(leftover['favoriteReachIds'], isEmpty);
        expect(leftover['fcmTokens'], isEmpty);
        expect(leftover['enableNotifications'], isFalse);
      }
      expect(ds.deletedUids, contains('guest-uid'));
    });

    test('a failed sign-in does not touch the guest document at all',
        () async {
      // REGRESSION, build 832 (2026-09-22). The first implementation cleared
      // the guest's favourites BEFORE attempting the sign-in and restored
      // them on failure. The restore did not happen and a tester lost two
      // saved rivers; the document was left with `mergePending: true` and an
      // empty list. Nothing may be written until the sign-in has succeeded.
      ds.signInThrows = true;
      final before = await doc('guest-uid');

      final result = await service.signInWithEmailAndPassword(
        email: 'me@example.com',
        password: 'wrong',
      );

      expect(result.isSuccess, isFalse);
      final after = await doc('guest-uid');
      expect(after, equals(before),
          reason: 'a failed sign-in must be a no-op on the guest document');
      expect(after!['mergePending'], isNull,
          reason: 'the fingerprint of the destroy-first design');
    });

    test('an abandoned sign-in leaves the rivers alone', () async {
      // The worse half of the same bug: the user taps Sign In, changes their
      // mind, and never completes. Any write that happens before success is
      // a write nobody undoes.
      final before = await doc('guest-uid');
      ds.signInThrows = true;
      await service.signInWithEmailAndPassword(
          email: 'x@y.com', password: 'nope');
      await service.signInWithEmailAndPassword(
          email: 'x@y.com', password: 'nope-again');

      expect(await doc('guest-uid'), equals(before));
    });

    test('an account signing in normally is not treated as a merge', () async {
      ds.user = MockUser(uid: 'someone-else', email: 'x@y.com');

      await service.signInWithEmailAndPassword(
        email: 'me@example.com',
        password: 'hunter2',
      );

      expect(ds.deletedUids, isEmpty,
          reason: 'only an ANONYMOUS previous session is an abandoned guest');
    });
  });

  group('the account prompt is shown once', () {
    test('marking it is recorded on the document, not the device', () async {
      await service.signInAnonymously();

      await service.markAccountPromptShown('guest-uid');

      expect((await doc('guest-uid'))!['accountPromptShown'], isTrue);
    });
  });
}
