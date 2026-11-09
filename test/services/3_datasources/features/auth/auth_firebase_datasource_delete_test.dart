// test/services/3_datasources/features/auth/auth_firebase_datasource_delete_test.dart
//
// ADR 0014 rule 2, pinned against the REAL datasource for the first time.
//
// `User.delete()` acts on the current SESSION, not on the reference it is
// called through. Build 843 (2026-09-25) called it on a stale anonymous
// reference after sign-in had already switched the session, and it deleted
// the account that had just signed in: a real account of eight months, while
// the anonymous user it was meant to remove survived. So the datasource
// refuses to act on anyone but the current user.
//
// WHY THIS FILE EXISTS. A 2026-11-09 mutation audit deleted that refusal and
// all 1,494 tests stayed green. The guards that look like they cover it live
// in `guest_mode_test.dart` and `guest_merge_destroy_test.dart`, and both
// drive a `_FakeDatasource` whose own `deleteUser` reimplements the refusal —
// one of them says so in a comment, "mirrors the real datasource's refusal",
// which is the tell. They prove the FAKE refuses. Nothing proved production
// did.
//
// That is the second of the three vacuity mechanisms the audit found, and
// the most expensive one in this project's history: the thing it failed to
// protect is the defect that destroyed a real account.

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/3_datasources/features/auth/auth_firebase_datasource.dart';

/// A [MockUser] that records whether `delete()` was actually reached.
///
/// `MockUser.delete()` is a no-op, so without this the "it does go through
/// for the current user" half could pass while the call never happened —
/// which is the same vacuity this file exists to remove.
/// The log is a `final` field holding a mutable list rather than a counter,
/// because [MockUser] is `@immutable` and a non-final field trips
/// `must_be_immutable`.
///
/// The ignore is for `MockUser`'s OWN non-final `_displayName` and
/// `_photoURL`, inside the package, which every subclass of it inherits. The
/// generated mocks in `fcm_service_test.mocks.dart` suppress the same thing
/// file-wide for the same reason.
// ignore: must_be_immutable
class _RecordingUser extends MockUser {
  _RecordingUser({
    required String uid,
    super.isAnonymous,
    List<String>? deleted,
  })  : deleted = deleted ?? <String>[],
        super(uid: uid);

  final List<String> deleted;

  @override
  Future<void> delete() async => deleted.add(uid);
}

void main() {
  test('it REFUSES to delete anyone but the current user', () async {
    // The exact shape of build 843: an account is signed in, and a stale
    // reference to the anonymous guest is still in hand.
    final account = _RecordingUser(uid: 'real-account-of-eight-months');
    final staleGuest = _RecordingUser(uid: 'orphaned-guest', isAnonymous: true);
    final auth = MockFirebaseAuth(signedIn: true, mockUser: account);
    final ds = AuthFirebaseDatasource(firebaseAuth: auth);

    await expectLater(
      ds.deleteUser(staleGuest),
      throwsA(isA<StateError>()),
      reason: 'User.delete() acts on the CURRENT session, so calling it '
          'through a stale reference deletes the wrong account. A stale '
          'reference is always a bug, so it must throw rather than guess',
    );

    expect(staleGuest.deleted, isEmpty);
    expect(account.deleted, isEmpty,
        reason: 'and above all it must not have deleted the signed-in '
            'account, which is exactly what happened in build 843');
    expect(auth.currentUser?.uid, 'real-account-of-eight-months',
        reason: 'the session is intact');
  });

  test('it DOES delete the current user', () async {
    // The positive control. Without it the refusal could be "always throw",
    // which would break account deletion entirely — itself an App Store
    // 5.1.1(v) requirement this app had to ship once already.
    final me = _RecordingUser(uid: 'me');
    final ds = AuthFirebaseDatasource(
      firebaseAuth: MockFirebaseAuth(signedIn: true, mockUser: me),
    );

    await ds.deleteUser(me);

    expect(me.deleted, ['me'],
        reason: 'the real deletion has to actually go through');
  });

  test('it refuses when nobody is signed in', () async {
    // `currentUser` is null during sign-out races and on a cold start before
    // Firebase restores the session. Deleting then is a guess, and the guess
    // is what cost the account.
    final orphan = _RecordingUser(uid: 'orphan', isAnonymous: true);
    final ds = AuthFirebaseDatasource(
      firebaseAuth: MockFirebaseAuth(signedIn: false),
    );

    await expectLater(ds.deleteUser(orphan), throwsA(isA<StateError>()));
    expect(orphan.deleted, isEmpty);
  });

  test('the refusal names both uids, because the log is the only witness',
      () async {
    // This failure is silent by nature: the wrong account is gone and the
    // app carries on. Whatever reaches the log has to say which uid was
    // asked for and which one was current, or the next person cannot tell
    // this apart from a Firebase error.
    final ds = AuthFirebaseDatasource(
      firebaseAuth:
          MockFirebaseAuth(signedIn: true, mockUser: _RecordingUser(uid: 'cur')),
    );

    try {
      await ds.deleteUser(_RecordingUser(uid: 'asked'));
      fail('expected a refusal');
    } on StateError catch (e) {
      expect(e.message, contains('asked'));
      expect(e.message, contains('cur'));
    }
  });
}
