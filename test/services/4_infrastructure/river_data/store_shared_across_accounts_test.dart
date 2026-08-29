// test/services/4_infrastructure/river_data/store_shared_across_accounts_test.dart
//
// ADR 0011 Phase 5 guard 2: "Two devices, two different accounts, one reach ->
// identical values. The requirement that motivated the design."
//
// The physical half of that guard — two phones, two logins, the same number on
// screen at the same moment — needs two phones and stays Jerson's to run. This
// file pins the half that a machine can settle: that nothing in the read path
// is keyed, scoped, filtered or permissioned by WHO is asking.
//
// It exists because guard 2 previously rested on a design argument rather than
// on an assertion. The argument was correct — document ids are
// `<source>__<reachId>__<product>` and the collection is top-level — but
// nothing failed the build if a later change nested the collection under
// `users/{uid}` or narrowed the read rule to an owner check.
//
// Which of these the suite already caught was measured, not assumed. Three
// mutations, each run against the whole suite:
//
//   | Mutation                              | Caught by |
//   |---------------------------------------|-----------|
//   | user segment appended to `storageKey` | 35 existing tests |
//   | `kStoreCollection` -> `users/uid/...` | this file only |
//   | read rule -> `auth.uid == data.userId`| this file only |
//
// So the key was never the exposure: too much of the suite pins its exact
// string. The other two were, and for the same reason — every other test takes
// `kStoreCollection` as a variable and never reads `firestore.rules` at all, so
// both mutations follow the change and stay green while two real phones would
// diverge.
//
// These are ABSENCE tests. They assert that a user identity does not appear
// where one would have to appear for two accounts to disagree. Absence tests
// age badly when they are vague, so each one names the specific mistake it is
// there to catch.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';

/// Two accounts that might plausibly be signed in on the two test devices.
const String _accountA = 'tOJIDsbkqgcNF03rXF1TVVchUI52';
const String _accountB = 'Zq8WvNb2LkR7yTgH4mCpX1sEdA93';

void main() {
  group('guard 2: the document a reach resolves to is user-independent', () {
    test('the storage key is built from the reach alone', () {
      const key = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '18471070',
        product: ForecastProduct.shortRange,
      );
      expect(key.storageKey, 'nwm__18471070__shortRange');
    });

    test('no account id can reach the key, because it takes no account id', () {
      // Constructing the same key twice, as two different signed-in users
      // would, yields the same string. There is no third argument to differ
      // on — which is the property, stated as a test so it cannot be quietly
      // given one.
      const a = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '18471070',
        product: ForecastProduct.shortRange,
      );
      const b = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '18471070',
        product: ForecastProduct.shortRange,
      );
      expect(a.storageKey, b.storageKey);
      expect(a.storageKey, isNot(contains(_accountA)));
      expect(a.storageKey, isNot(contains(_accountB)));
    });

    test('the watch set for one reach is the same for either account', () {
      // documentIdsFor is the only thing that decides which documents a device
      // subscribes to. It takes favourites and nothing else; if two accounts
      // favourite the same river they must watch byte-identical ids.
      const favourite = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '18471070',
        product: ForecastProduct.shortRange,
      );

      final forA = StoreSubscriptionService.documentIdsFor([favourite]);
      final forB = StoreSubscriptionService.documentIdsFor([favourite]);

      expect(forA, equals(forB));
      expect(forA, isNotEmpty);
      for (final id in forA) {
        expect(id, isNot(contains(_accountA)));
        expect(id, isNot(contains(_accountB)));
        expect(id, startsWith('nwm__18471070__'));
      }
    });

    test('a GEOGLOWS favourite is user-independent too', () {
      const favourite = RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '240227859',
        product: ForecastProduct.geoglowsForecast,
      );
      final ids = StoreSubscriptionService.documentIdsFor([favourite]);
      expect(ids, contains('geoglows__240227859__geoglowsForecast'));
      for (final id in ids) {
        expect(id, isNot(contains(_accountA)));
      }
    });
  });

  group('guard 2: the collection is shared, not per-user', () {
    test('the store collection is a top-level name with no path segments', () {
      // `users/$uid/river_data` would satisfy every other test in the suite
      // and give each account its own copy of every forecast — the exact
      // failure guard 2 exists to catch, invisible without two devices.
      expect(kStoreCollection, 'river_data');
      expect(kStoreCollection, isNot(contains('/')));
      expect(kStoreCollection, isNot(contains('{')));
      expect(kStoreCollection, isNot(contains(r'$')));
    });
  });

  group('guard 2: the security rule admits any signed-in account', () {
    // Read off disk, the same technique the Cloud Functions tests use to pin
    // cross-language contracts. The deployed rule is what actually decides
    // whether account B can read what account A can, and it lives outside Dart.
    late String rules;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      rules = await _readRepoFile('firestore.rules');
    });

    test('river_data has a rule at all', () {
      // It went missing once in a way nothing caught: the rule was committed
      // 2026-08-24 but only `firestore:indexes` was ever deployed, so every
      // store read was denied on device while every test stayed green.
      expect(rules, contains('match /river_data/{documentId}'));
    });

    test('read is granted on being signed in, not on being the owner', () {
      final block = _ruleBlock(rules, 'river_data');
      expect(block, contains('allow read: if request.auth != null'));
      // An owner check is the plausible "tightening" that would break guard 2.
      expect(block, isNot(contains('request.auth.uid ==')));
      expect(block, isNot(contains('resource.data.userId')));
    });

    test('nobody may write, so one account cannot alter what another sees', () {
      final block = _ruleBlock(rules, 'river_data');
      expect(block, contains('allow write: if false'));
    });
  });
}

/// The text of one `match /<collection>/{...}` block, braces balanced.
String _ruleBlock(String rules, String collection) {
  final start = rules.indexOf('match /$collection/');
  expect(start, isNot(-1), reason: 'no match block for $collection');
  // The header line is `match /river_data/{documentId} {`. Its FIRST brace
  // belongs to the path wildcard, not to the block — starting there closed the
  // scan on `{documentId}` and returned the header alone, which then passed a
  // `isNot(contains(...))` assertion for entirely the wrong reason.
  final headerEnd = rules.indexOf('\n', start);
  final open = rules.lastIndexOf('{', headerEnd);
  var depth = 0;
  for (var i = open; i < rules.length; i++) {
    if (rules[i] == '{') depth++;
    if (rules[i] == '}') {
      depth--;
      if (depth == 0) return rules.substring(start, i + 1);
    }
  }
  fail('unbalanced braces in the $collection rule');
}

/// Read a file from the repo root.
///
/// Tests run with the package root as the working directory, so a plain
/// relative path is enough; rootBundle would only see declared assets.
Future<String> _readRepoFile(String relativePath) async {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail('$relativePath not found from ${Directory.current.path}');
  }
  return file.readAsString();
}
