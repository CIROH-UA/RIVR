// ignore_for_file: subtype_of_sealed_class
//
// The Firestore types are sealed, and this test implements them anyway.
//
// It has to: the defect under test is what happens when a document READ
// FAILS, and `fake_cloud_firestore` has no way to make one fail on demand.
// A fake that cannot fail cannot exercise the failure. The alternative is a
// test that proves nothing, which is the failure mode an audit of this
// suite measured at 22% on 2026-11-09.
//
// Scope is one file and the warning is suppressed deliberately, not
// silently: `flutter analyze` is treated as a gate here and was clean
// before this file existed.

// PHASE 2 BASELINE — MUST FAIL against HEAD b2aa2ac.
//
// Defect #1 (audit D/A2). `AuthService._mergeGuestIntoAccount`
// (lib/services/4_infrastructure/auth/auth_service.dart:306) does
//
//     final account = await _readUserDoc(accountUid) ?? <String, dynamic>{};
//
// and `_readUserDoc` (:281-292) catches EVERY exception and returns null. A
// timeout, an offline read, or a permission-denied from a token that has not
// propagated yet is therefore indistinguishable from "this account has no
// document". `mergedIds` becomes the guest's ids ALONE and :325 writes
// `favoriteReachIds`, `favoriteSources`, `favoriteLabels` and
// `alertFrequencies` over the account's own — arrays are REPLACED by a
// merge-write, not unioned.
//
// This is the 832 incident (a tester's two saved rivers destroyed) reached by
// a new route, and it happens on a SUCCESSFUL write, so no error path fires
// and nothing is logged as a failure.
//
// The rule this repo learned from 832: nothing is written until the operation
// it depends on has SUCCEEDED. A read that failed has not succeeded, so no
// merge may be written on it.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_auth_mocks/src/mock_user_credential.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/services/3_datasources/features/auth/auth_firebase_datasource.dart';
import 'package:rivr/services/4_infrastructure/auth/auth_service.dart';

// ---------------------------------------------------------------------------
// A Firestore whose read of ONE document fails, and whose writes all land.
// Everything else forwards to a real FakeFirebaseFirestore.
// ---------------------------------------------------------------------------

class _FlakyReadFirestore implements FirebaseFirestore {
  _FlakyReadFirestore(this._inner, this.failReadsForDocId);
  final FirebaseFirestore _inner;
  final String failReadsForDocId;
  int failedReads = 0;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _FlakyCollection(_inner.collection(path), this);

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('not needed by this test: ${i.memberName}');
}

class _FlakyCollection implements CollectionReference<Map<String, dynamic>> {
  _FlakyCollection(this._inner, this._db);
  final CollectionReference<Map<String, dynamic>> _inner;
  final _FlakyReadFirestore _db;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _FlakyDoc(_inner.doc(path), _db, path == _db.failReadsForDocId);

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('not needed by this test: ${i.memberName}');
}

class _FlakyDoc implements DocumentReference<Map<String, dynamic>> {
  _FlakyDoc(this._inner, this._db, this._fail);
  final DocumentReference<Map<String, dynamic>> _inner;
  final _FlakyReadFirestore _db;
  final bool _fail;

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    if (_fail) {
      _db.failedReads++;
      // Exactly what an unpropagated token or a dropped connection looks like.
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
        message: 'simulated transient read failure',
      );
    }
    return _inner.get(options);
  }

  // Writes are NOT impaired: the point of the defect is that the write
  // succeeds while the read it depended on did not.
  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) =>
      _inner.set(data, options);

  @override
  Future<void> update(Map<Object, Object?> data) => _inner.update(data);

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('not needed by this test: ${i.memberName}');
}

// ---------------------------------------------------------------------------

class _FakeDatasource extends AuthFirebaseDatasource {
  _FakeDatasource() : super(firebaseAuth: MockFirebaseAuth());

  fb.User? user;

  @override
  fb.User? get currentUser => user;

  @override
  Future<fb.UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    user = MockUser(uid: 'account-uid', email: email);
    return MockUserCredential(false, mockUser: user as MockUser);
  }

  @override
  Future<void> deleteUser(fb.User user) async =>
      throw StateError('nothing may be deleted on the sign-in path');
}

void main() {
  test('a FAILED read of the account document must not replace the account\'s '
      'saved rivers with the guest\'s', () async {
    final inner = FakeFirebaseFirestore();

    // The account: eight months of use, six saved rivers, a rename and an
    // alert setting the person chose.
    await inner.collection('users').doc('account-uid').set({
      'userId': 'account-uid',
      'email': 'jerson@example.com',
      'isGuest': false,
      'favoriteReachIds': ['10376605', '23021904', '10092062', '3624735',
        '5781369', '19085482'],
      'favoriteSources': {'10376605': 'nwm', '23021904': 'nwm'},
      'favoriteLabels': {'nwm:10376605': "Dad's Fishing Hole"},
      'alertFrequencies': {'10376605': 'daily'},
    });

    // The guest: browsed the map, tapped one river.
    await inner.collection('users').doc('guest-uid').set({
      'userId': 'guest-uid',
      'isGuest': true,
      'favoriteReachIds': ['99999999'],
      'favoriteSources': {'99999999': 'geoglows'},
      'favoriteLabels': <String, String>{},
      'alertFrequencies': <String, String>{},
    });

    // The ONE read that fails is the account document, inside the merge.
    final db = _FlakyReadFirestore(inner, 'account-uid');
    final ds = _FakeDatasource()
      ..user = MockUser(isAnonymous: true, uid: 'guest-uid');
    final service = AuthService(authDatasource: ds, firestore: db);

    final result = await service.signInWithEmailAndPassword(
      email: 'jerson@example.com',
      password: 'correct-password',
    );

    expect(result.isSuccess, isTrue, reason: 'the sign-in itself succeeds');
    expect(db.failedReads, greaterThan(0),
        reason: 'the harness must actually have broken a read');

    final after =
        (await inner.collection('users').doc('account-uid').get()).data()!;

    // ---- The assertions that FAIL today ----
    expect(
      after['favoriteReachIds'],
      containsAll(<String>['10376605', '23021904', '10092062', '3624735',
        '5781369', '19085482']),
      reason: 'a failed read must never be treated as "the account has no '
          'rivers"; nothing may be written until the read has SUCCEEDED',
    );
    expect(after['favoriteLabels'],
        containsPair('nwm:10376605', "Dad's Fishing Hole"),
        reason: 'the account\'s own rename must survive');
    expect(after['alertFrequencies'], containsPair('10376605', 'daily'),
        reason: 'the account\'s own alert setting must survive');
  });
}
