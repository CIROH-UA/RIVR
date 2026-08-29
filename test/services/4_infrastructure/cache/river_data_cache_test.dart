// test/services/4_infrastructure/cache/river_data_cache_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/4_infrastructure/cache/river_data_cache.dart';

void main() {
  phase2Tests();
  guard9EvictOrderingTests();
  phase2Round2Tests();
  late Directory tempDir;

  const key = RiverDataKey(
    source: ForecastSource.nwm,
    reachId: '23021904',
    product: ForecastProduct.shortRange,
  );

  RiverDataEntry entryWith(double value) => RiverDataEntry(
    key: key,
    window: FreshnessWindow(
      fetchedAt: DateTime.utc(2026, 7, 10, 12, 0),
      validUntil: DateTime.utc(2026, 7, 10, 13, 0),
    ),
    unit: 'CMS',
    payload: {'currentFlow': value},
  );

  RiverDataCache newCache() =>
      RiverDataCache(cacheDirProvider: () async => tempDir);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('rivr_cache_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('put then get returns the entry from memory', () async {
    final cache = newCache();
    await cache.initialize();

    await cache.put(entryWith(100));
    final got = await cache.get(key);

    expect(got, isNotNull);
    expect(got!.payload['currentFlow'], 100);
  });

  test('get returns null for an unknown key', () async {
    final cache = newCache();
    await cache.initialize();
    expect(await cache.get(key), isNull);
  });

  test('persists to disk — a fresh instance hydrates from the same dir',
      () async {
    final writer = newCache();
    await writer.initialize();
    await writer.put(entryWith(250));

    // Simulate a new app launch: brand-new cache object, same directory.
    final reader = newCache();
    await reader.initialize();
    final got = await reader.get(key);

    expect(got, isNotNull);
    expect(got!.payload['currentFlow'], 250);
    expect(got.window.validUntil, DateTime.utc(2026, 7, 10, 13, 0));
  });

  test('listenable notifies observers on put (one fetch fans out)', () async {
    final cache = newCache();
    await cache.initialize();

    final listenable = cache.listenable(key);
    var notifications = 0;
    listenable.addListener(() => notifications++);

    expect(listenable.value, isNull);
    await cache.put(entryWith(300));

    expect(notifications, 1);
    expect(listenable.value!.payload['currentFlow'], 300);
  });

  test('evict removes from memory, disk, and observers', () async {
    final cache = newCache();
    await cache.initialize();
    await cache.put(entryWith(400));

    await cache.evict(key);

    expect(await cache.get(key), isNull);
    expect(cache.listenable(key).value, isNull);
    // fresh instance also sees nothing on disk
    final reader = newCache();
    await reader.initialize();
    expect(await reader.get(key), isNull);
  });

  test('clear drops everything', () async {
    final cache = newCache();
    await cache.initialize();
    await cache.put(entryWith(500));

    await cache.clear();

    expect(await cache.get(key), isNull);
  });

  test('put still works before initialize (memory only, no crash)', () async {
    final cache = newCache(); // not initialized -> _dir == null
    await cache.put(entryWith(600));
    expect((await cache.get(key))!.payload['currentFlow'], 600);
  });
}

// ─── ADR 0011 Phase 2 — retention discipline ─────────────────────────────────
//
// Before this phase NOTHING pruned the store: evict()/clear() existed and
// nothing called them, so browsing left one file set per reach forever. These
// tests are the phase's guards; each was run against a mutated cache (cap
// ignored, pins ignored, sweep deleted, schema check deleted) before landing.

/// A key for [reachId], any product.
RiverDataKey _keyFor(String reachId,
        [ForecastProduct product = ForecastProduct.shortRange]) =>
    RiverDataKey(
        source: ForecastSource.nwm, reachId: reachId, product: product);

RiverDataEntry _entryFor(String reachId,
        [ForecastProduct product = ForecastProduct.shortRange]) =>
    RiverDataEntry(
      key: _keyFor(reachId, product),
      window: FreshnessWindow(
        fetchedAt: DateTime.utc(2026, 8, 23, 12),
        validUntil: DateTime.utc(2026, 8, 23, 13),
      ),
      unit: 'CMS',
      payload: {'currentFlow': 1.0},
    );

void phase2Tests() {
  group('ADR 0011 Phase 2 — retention', () {
  late Directory tempDir;

  RiverDataCache newCache({int cap = 3}) => RiverDataCache(
      cacheDirProvider: () async => tempDir, maxNonPinnedReaches: cap);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('rivr_cache_p2_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('guard 2 — LRU cap on non-pinned reaches, favourites never evicted',
      () {
    test('exceeding the cap evicts the least-recently-used reach', () async {
      final cache = newCache(cap: 3);
      await cache.initialize();

      await cache.put(_entryFor('1'));
      await cache.put(_entryFor('2'));
      await cache.put(_entryFor('3'));
      // Touch reach 1 so reach 2 becomes the LRU.
      await cache.get(_keyFor('1'));
      await cache.put(_entryFor('4'));

      expect(await cache.get(_keyFor('2')), isNull,
          reason: 'reach 2 was the least recently used beyond the cap');
      expect(await cache.get(_keyFor('1')), isNotNull,
          reason: 'reach 1 was touched after reach 2 — recency must matter, '
              'not insertion order');
      expect(await cache.get(_keyFor('4')), isNotNull);
    });

    test('a reach is evicted whole — every product goes together', () async {
      final cache = newCache(cap: 1);
      await cache.initialize();

      await cache.put(_entryFor('1', ForecastProduct.shortRange));
      await cache.put(_entryFor('1', ForecastProduct.reachMetadata));
      await cache.put(_entryFor('2'));

      expect(await cache.get(_keyFor('1', ForecastProduct.shortRange)), isNull);
      expect(await cache.get(_keyFor('1', ForecastProduct.reachMetadata)),
          isNull,
          reason: 'half-evicted reaches are a corrupt state — a name with no '
              'flow entry that will never refetch together');
    });

    test('a pinned reach survives the cap however old', () async {
      final cache = newCache(cap: 2);
      await cache.initialize();
      cache.setPinnedReaches({'fav'});

      await cache.put(_entryFor('fav')); // oldest access of all
      await cache.put(_entryFor('1'));
      await cache.put(_entryFor('2'));
      await cache.put(_entryFor('3')); // pushes non-pinned over the cap

      expect(await cache.get(_keyFor('fav')), isNotNull,
          reason: 'favourites are pinned — the cap must never touch them');
      expect(await cache.get(_keyFor('1')), isNull,
          reason: 'the eviction lands on the oldest NON-pinned reach instead');
    });

    test('a cap exceeded entirely by favourites evicts nothing', () async {
      final cache = newCache(cap: 2);
      await cache.initialize();
      cache.setPinnedReaches({'f1', 'f2', 'f3', 'f4'});

      await cache.put(_entryFor('f1'));
      await cache.put(_entryFor('f2'));
      await cache.put(_entryFor('f3'));
      await cache.put(_entryFor('f4'));

      for (final id in ['f1', 'f2', 'f3', 'f4']) {
        expect(await cache.get(_keyFor(id)), isNotNull,
            reason: 'pinned reaches do not count against the cap, so 4 '
                'favourites over a cap of 2 is not an overflow');
      }
    });

    test('disk files are deleted with the eviction, not just memory', () async {
      final cache = newCache(cap: 1);
      await cache.initialize();

      await cache.put(_entryFor('1'));
      await cache.put(_entryFor('2'));

      final files = tempDir.listSync().whereType<File>().toList();
      expect(files, hasLength(1),
          reason: 'an eviction that leaves the file is not retention — the '
              'disk is the thing being bounded');
      expect(files.single.path, contains('__2__'));
    });
  });

  group('guard 3 — the cache stays bounded under browsing', () {
    test('browsing many reaches stabilises at the cap', () async {
      final cache = newCache(cap: 5);
      await cache.initialize();

      for (var i = 0; i < 40; i++) {
        await cache.put(_entryFor('$i', ForecastProduct.shortRange));
        await cache.put(_entryFor('$i', ForecastProduct.reachMetadata));
      }

      final files = tempDir.listSync().whereType<File>().length;
      expect(files, 5 * 2,
          reason: '40 browsed reaches × 2 products must leave exactly '
              'cap × products files — unbounded growth is the pre-Phase-2 '
              'behaviour this guard exists to prevent');
    });
  });

  group('guard 4 — favouriting a browsed reach costs nothing', () {
    test('pinning after the fact serves the same entry from cache', () async {
      final cache = newCache(cap: 3);
      await cache.initialize();

      await cache.put(_entryFor('42'));
      // The user favourites the reach they were just looking at.
      cache.setPinnedReaches({'42'});

      final got = await cache.get(_keyFor('42'));
      expect(got, isNotNull,
          reason: 'pinning must not invalidate — the entry is already right');
      expect(got!.payload['currentFlow'], 1.0);
    });

    test('pinning protects the reach from the very next eviction', () async {
      final cache = newCache(cap: 1);
      await cache.initialize();

      await cache.put(_entryFor('42'));
      cache.setPinnedReaches({'42'});
      await cache.put(_entryFor('99'));

      expect(await cache.get(_keyFor('42')), isNotNull,
          reason: 'a reach favourited mid-session is pinned from that moment');
    });
  });

  group('guard 5 — unrecognised schema versions are discarded, not parsed', () {
    test('a pre-versioning file is deleted on initialize', () async {
      // Pre-Phase-2 filename: no version suffix.
      final legacy = File('${tempDir.path}/nwm__1__shortRange.json');
      await legacy
          .writeAsString('{"source":"nwm","reachId":"1","product":"shortRange"}');

      final cache = newCache();
      await cache.initialize();

      expect(await legacy.exists(), isFalse,
          reason: 'parsing an old shape with a new codec is how upgrades '
              'corrupt; the only safe read of an unrecognised version is none');
      expect(await cache.get(_keyFor('1')), isNull);
    });

    test('a future schema version is deleted too, not parsed', () async {
      final future = File('${tempDir.path}/nwm__1__shortRange.v99.json');
      await future.writeAsString('{"schema":99}');

      final cache = newCache();
      await cache.initialize();

      expect(await future.exists(), isFalse,
          reason: 'a downgrade meets files from the future; same rule');
    });

    test('a right-suffix file with a wrong embedded version is discarded on '
        'read', () async {
      // The filename lies about its content — belt and braces. The entry is
      // WELL-FORMED apart from its version: round 4 caught the previous
      // fixture omitting `window`, so the parse-failure catch did the work and
      // the version check was deletable — two redundant checks covering for
      // each other, this suite's oldest lesson.
      final cache = newCache();
      await cache.initialize();
      final wellFormed = _entryFor('7').toJson()..['schema'] = 0;
      final f = File(
          '${tempDir.path}/nwm__7__shortRange.v${RiverDataEntry.schemaVersion}.json');
      await f.writeAsString(jsonEncode(wellFormed));

      expect(await cache.get(_keyFor('7')), isNull,
          reason: 'parseable is not the same as recognised — only the version '
              'check can reject this one');
      expect(await f.exists(), isFalse);
    });

    test('current-version files survive the sweep', () async {
      final writer = newCache();
      await writer.initialize();
      await writer.put(_entryFor('1'));

      final reader = newCache();
      await reader.initialize();

      expect(await reader.get(_keyFor('1')), isNotNull,
          reason: 'the sweep must only discard foreign versions');
    });
  });

  group('run supersession, not wall-clock', () {
    test('an entry years old is still served — no time-based deletion',
        () async {
      final cache = newCache();
      await cache.initialize();
      await cache.put(RiverDataEntry(
        key: _keyFor('1'),
        window: FreshnessWindow(
          fetchedAt: DateTime.utc(2020, 1, 1),
          validUntil: DateTime.utc(2020, 1, 2),
        ),
        unit: 'CMS',
        payload: {'currentFlow': 5.0},
      ));

      final got = await cache.get(_keyFor('1'));
      expect(got, isNotNull,
          reason: 'age never deletes: staleness is the repository\'s '
              'revalidation signal, not a retention policy. The entry is '
              'the newest data this device has for a run that, offline, '
              'may still be current');
    });
  });
  });
}


// Appended after round 1 of the Phase 2 review, which proved each of these
// properties breakable with all 1019 tests green — and one of them (the
// cold-start pin gap) breakable in production on every restart.
void phase2Round2Tests() {
  group('ADR 0011 Phase 2 — round 2 guards', () {
    late Directory tempDir;

    RiverDataCache newCache({int cap = 3}) => RiverDataCache(
        cacheDirProvider: () async => tempDir, maxNonPinnedReaches: cap);

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rivr_cache_p2b_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    // REGRESSION (round 1, F1 — a live bug): pins were memory-only, so at
    // every cold start the first put — a map tap, a notification, a background
    // refresh — enforced the cap against an all-unpinned world and deleted
    // last session's favourite from disk, before the Firestore favourites load
    // could ever declare it.
    test('a favourite survives a cold-start put made before pins arrive',
        () async {
      final s1 = newCache(cap: 2);
      await s1.initialize();
      s1.setPinnedReaches({'fav'});
      await s1.put(_entryFor('fav'));
      await s1.put(_entryFor('a'));
      await s1.put(_entryFor('b'));

      // New launch, same dir. NO setPinnedReaches yet — favourites are still
      // loading from Firestore when the first put lands.
      final s2 = newCache(cap: 2);
      await s2.put(_entryFor('newlyBrowsed'));

      expect(await s2.get(_keyFor('fav')), isNotNull,
          reason: 'the pin set persists with the cache; a favourite must '
              'never be evictable in the gap before the favourites load');
    });

    test('a fresh declaration beats the persisted pins', () async {
      final s1 = newCache();
      await s1.initialize();
      s1.setPinnedReaches({'old'});
      await s1.put(_entryFor('old'));

      final s2 = newCache(cap: 1);
      await s2.initialize();
      s2.setPinnedReaches({'new'}); // the account changed its favourites
      await s2.put(_entryFor('new'));
      await s2.put(_entryFor('filler'));

      expect(await s2.get(_keyFor('old')), isNull,
          reason: 'the persisted set is a bridge to the next declaration, '
              'not an accumulating shield');
      expect(await s2.get(_keyFor('new')), isNotNull);
    });

    // The race inside F1's fix: a declaration that arrives BEFORE init
    // completes must not be overwritten by the persisted file init then loads.
    // Favourites can beat the first disk touch on a warm Firestore cache.
    test('a declaration made before init survives the persisted-pin load',
        () async {
      final s1 = newCache();
      await s1.initialize();
      s1.setPinnedReaches({'old'});
      await s1.put(_entryFor('old'));

      final s2 = newCache(cap: 1);
      s2.setPinnedReaches({'new'}); // arrives before any init-triggering op
      await s2.initialize();
      await s2.put(_entryFor('new'));
      await s2.put(_entryFor('filler'));

      expect(await s2.get(_keyFor('new')), isNotNull,
          reason: 'the fresh declaration is the truth; the persisted file is '
              'only a bridge for sessions that have not declared yet');
      expect(await s2.get(_keyFor('old')), isNull);
    });

    // REGRESSION (round 1, F4): every earlier test kept one warm instance, so
    // the disk-scan branch of _enforceCap — the thing that makes the cap true
    // across restarts — was entirely deletable.
    test('the cap holds against files from a previous session', () async {
      final s1 = newCache(cap: 30);
      await s1.initialize();
      for (var i = 0; i < 10; i++) {
        await s1.put(_entryFor('$i'));
      }

      final s2 = newCache(cap: 3);
      await s2.initialize();
      await s2.put(_entryFor('fresh'));

      final files = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('__'))
          .length;
      expect(files, 3,
          reason: 'groups the new instance has never seen in memory must '
              'still count and still evict — otherwise the bound only exists '
              'within one session');
    });

    test('cross-restart eviction is by file age, oldest first', () async {
      final s1 = newCache(cap: 30);
      await s1.initialize();
      await s1.put(_entryFor('older'));
      await s1.put(_entryFor('newer'));
      // Make the ages unambiguous — filesystem mtime granularity is coarse.
      final now = DateTime.now();
      for (final f in tempDir.listSync().whereType<File>()) {
        f.setLastModifiedSync(f.path.contains('__older__')
            ? now.subtract(const Duration(days: 2))
            : now.subtract(const Duration(hours: 1)));
      }

      final s2 = newCache(cap: 2);
      await s2.initialize();
      await s2.put(_entryFor('fresh'));

      expect(await s2.get(_keyFor('older')), isNull,
          reason: 'unseen groups fall back to file mtime — without it the '
              'eviction order across a restart is arbitrary');
      expect(await s2.get(_keyFor('newer')), isNotNull);
    });

    // REGRESSION (round 1, F5): only the memory-hit _touch was guarded. A
    // reach hydrated from DISK landed with no recency at all, so after a
    // restart the reach the user just opened was the first eviction victim.
    test('reading a disk entry refreshes its recency', () async {
      final s1 = newCache(cap: 30);
      await s1.initialize();
      await s1.put(_entryFor('opened'));
      await s1.put(_entryFor('ignored'));
      final now = DateTime.now();
      for (final f in tempDir.listSync().whereType<File>()) {
        f.setLastModifiedSync(f.path.contains('__opened__')
            ? now.subtract(const Duration(days: 2))
            : now.subtract(const Duration(hours: 1)));
      }

      final s2 = newCache(cap: 2);
      await s2.initialize();
      await s2.get(_keyFor('opened')); // the user opens the old reach
      await s2.put(_entryFor('fresh'));

      expect(await s2.get(_keyFor('opened')), isNotNull,
          reason: 'the reach on screen was just read; evicting it because '
              'its FILE is old is evicting by the wrong clock');
      expect(await s2.get(_keyFor('ignored')), isNull);
    });

    // REGRESSION (round 1, F6): pinned reaches must be excluded from the COUNT
    // as well as the eviction. Counting them shrinks the browse budget by one
    // per favourite — invisible to the all-pinned fixture, which has nothing
    // evictable either way.
    test('favourites do not eat the browse budget', () async {
      final cache = newCache(cap: 3);
      await cache.initialize();
      cache.setPinnedReaches({'f1', 'f2'});

      await cache.put(_entryFor('f1'));
      await cache.put(_entryFor('f2'));
      await cache.put(_entryFor('a'));
      await cache.put(_entryFor('b'));
      await cache.put(_entryFor('c'));

      for (final id in ['a', 'b', 'c']) {
        expect(await cache.get(_keyFor(id)), isNotNull,
            reason: 'cap 3 means 3 NON-pinned reaches; counting the two '
                'favourites cuts the browse budget to one');
      }
    });

    // REGRESSION (round 1, F7): nothing anywhere un-pinned. Accumulating pins
    // permanently shields reaches the user has un-favourited.
    test('a removed favourite becomes evictable again', () async {
      final cache = newCache(cap: 1);
      await cache.initialize();
      cache.setPinnedReaches({'a'});
      await cache.put(_entryFor('a'));
      await cache.put(_entryFor('b')); // 'a' pinned, 'b' evict... b is LRU-newest
      expect(await cache.get(_keyFor('a')), isNotNull);

      cache.setPinnedReaches(const {}); // un-favourited
      await cache.put(_entryFor('c'));

      expect(await cache.get(_keyFor('a')), isNull,
          reason: 'setPinnedReaches REPLACES the set — accumulating turns '
              'every ex-favourite into a permanent squatter');
    });

    // REGRESSION (round 1, F8): memory-only mode (disk unavailable) skipped
    // the cap entirely — unbounded growth in the one thing this phase bounds.
    test('the cap holds in memory-only mode', () async {
      final cache = RiverDataCache(
        cacheDirProvider: () async => throw const FileSystemException('no disk'),
        maxNonPinnedReaches: 3,
      );

      for (var i = 0; i < 20; i++) {
        await cache.put(_entryFor('$i'));
      }

      var alive = 0;
      for (var i = 0; i < 20; i++) {
        if (await cache.get(_keyFor('$i')) != null) alive++;
      }
      expect(alive, 3,
          reason: 'no disk does not mean no bound');
    });

    // REGRESSION (round 1, F11): guard 3 counted files, so an eviction that
    // matched by bare prefix — where reach "1" collides with "10".."19" —
    // was invisible.
    test('evicting reach 1 does not take reach 10 with it', () async {
      final cache = newCache(cap: 2);
      await cache.initialize();

      await cache.put(_entryFor('1'));
      await cache.put(_entryFor('10'));
      await cache.put(_entryFor('2')); // evicts '1', the LRU

      expect(await cache.get(_keyFor('1')), isNull);
      expect(await cache.get(_keyFor('10')), isNotNull,
          reason: 'the group boundary is the __ separator; a bare prefix '
              'match evicts every reach that happens to share leading digits');
    });

    // Round 1, F12: the contract justifies source-agnostic pins at length and
    // nothing demonstrated them.
    test('a pin protects the reach id across sources', () async {
      final cache = newCache(cap: 1);
      await cache.initialize();
      cache.setPinnedReaches({'760021642'});

      const geoKey = RiverDataKey(
        source: ForecastSource.geoglows,
        reachId: '760021642',
        product: ForecastProduct.geoglowsForecast,
      );
      await cache.put(RiverDataEntry(
        key: geoKey,
        window: FreshnessWindow(
          fetchedAt: DateTime.utc(2026, 8, 23, 12),
          validUntil: DateTime.utc(2026, 8, 23, 13),
        ),
        unit: 'CMS',
        payload: {'currentFlow': 1.0},
      ));
      await cache.put(_entryFor('other'));

      expect(await cache.get(geoKey), isNotNull,
          reason: 'pins are bare reach ids by design — a GEOGLOWS favourite '
              'is as pinned as an NWM one');
    });

    // Round 1, F14: the reachable half of the corrupt-file story — a
    // truncated write is re-read and re-fails forever unless deleted.
    test('an unparseable file is deleted on read, not left to rot', () async {
      final cache = newCache();
      await cache.initialize();
      final f = File(
          '${tempDir.path}/nwm__9__shortRange.v${RiverDataEntry.schemaVersion}.json');
      await f.writeAsString('{"schema":'); // a truncated write

      expect(await cache.get(_keyFor('9')), isNull);
      expect(await f.exists(), isFalse,
          reason: 'left in place it counts against the cap and fails on '
              'every read until something overwrites it');
    });

    // REGRESSION (round 2, R2-F4): cap eviction reset memory and disk but the
    // observer reset was deletable — a widget bound via watch() would keep
    // rendering an entry the cache had dropped. evict() had this guard; the
    // eviction path this phase introduced did not.
    test('cap eviction nulls the observers too', () async {
      final cache = newCache(cap: 1);
      await cache.initialize();

      await cache.put(_entryFor('1'));
      final observed = cache.listenable(_keyFor('1'));
      expect(observed.value, isNotNull);

      await cache.put(_entryFor('2')); // evicts reach 1

      expect(observed.value, isNull,
          reason: 'an observer still holding the entry renders data the '
              'cache says does not exist');
    });

    // REGRESSION (round 2, R2-F3): the mtime fallback re-statted every disk
    // file on every put — the memoisation froze only the VALUE. Each disk
    // group must cost exactly one stat per session.
    test('the mtime fallback stats each group once, not once per put',
        () async {
      final s1 = newCache(cap: 30);
      await s1.initialize();
      for (var i = 0; i < 6; i++) {
        await s1.put(_entryFor('$i'));
      }

      final s2 = newCache(cap: 30);
      await s2.initialize();
      await s2.put(_entryFor('a'));
      final after1 = s2.statCallsForTesting;
      await s2.put(_entryFor('b'));
      await s2.put(_entryFor('c'));

      expect(after1, 6, reason: 'six unseen disk groups, six stats');
      expect(s2.statCallsForTesting, 6,
          reason: 'two more puts must add ZERO stats — this sits on the '
              'tap path (review round 2 measured ~11 ms per 3-put tap on a '
              'desktop SSD, flat, forever, with the unmemoised version)');
    });

    // REGRESSION (round 2, R2-F6): a fire-and-forget sign-out clear() racing
    // the next account's pin declaration deleted the new pins file — silently
    // re-opening the cold-start favourite eviction the pins file closes.
    test('clear racing a pin declaration keeps the newer pins', () async {
      final cache = newCache(cap: 1);
      await cache.initialize();
      cache.setPinnedReaches({'oldAccount'});

      final clearing = cache.clear(); // fire... (sign-out does not await)
      cache.setPinnedReaches({'newAccount'}); // ...next account logs in
      await clearing;
      // Let the serialised persist settle.
      await cache.put(_entryFor('newAccount'));

      final s2 = newCache(cap: 1);
      await s2.initialize();
      await s2.put(_entryFor('other'));

      expect(await s2.get(_keyFor('newAccount')), isNotNull,
          reason: 'the declaration came after the clear; losing its file '
              're-opens cold-start eviction of the new account\'s favourite');
    });

    // REGRESSION (round 2, R2-F7): the pins file was named with the ENTRY
    // schema version, so the entry-format upgrade it claimed to survive
    // deleted it.
    test('the pins file survives an entry-schema sweep', () async {
      final cache = newCache();
      await cache.initialize();
      cache.setPinnedReaches({'fav'});
      // Force the persist through.
      await cache.put(_entryFor('fav'));
      // A foreign-version entry triggers the discard path on next init.
      await File('${tempDir.path}/nwm__x__shortRange.v99.json')
          .writeAsString('{}');

      final s2 = newCache(cap: 1);
      await s2.initialize();
      await s2.put(_entryFor('other'));

      expect(await s2.get(_keyFor('fav')), isNotNull,
          reason: 'pins are a bare id list, format-independent of entries — '
              'the sweep must keep them or every upgrade un-pins everyone');
    });

    // REGRESSION (round 4, F2): _lastAccess is the third per-key map in the
    // class; _notifiers got a bound and a guard in round 3, this one got the
    // fix and no guard — both its cleanup sites were deletable.
    test('browsing does not grow the recency map without bound', () async {
      final cache = newCache(cap: 2);
      await cache.initialize();

      for (var i = 0; i < 30; i++) {
        await cache.put(_entryFor('$i'));
      }

      expect(cache.lastAccessCountForTesting, 2,
          reason: 'evicted groups must drop their recency entries — same '
              'unbounded-growth shape as the notifier map, one field over');
    });

    test('clear() empties the recency map', () async {
      final cache = newCache();
      await cache.initialize();
      await cache.put(_entryFor('1'));
      await cache.clear();

      expect(cache.lastAccessCountForTesting, 0);
    });

    // REGRESSION (round 4, F9): initialize() must not RETURN until the
    // persisted pins are loaded — an unawaited load reopens the cold-start
    // window round 1 closed, saved only by microtask luck in small fixtures.
    test('initialize returns with the persisted pins already loaded',
        () async {
      final s1 = newCache();
      await s1.initialize();
      s1.setPinnedReaches({'fav'});
      await s1.put(_entryFor('fav'));

      final s2 = newCache();
      await s2.initialize();

      // Synchronously after the await — no further turns of the loop.
      expect(s2.pinnedReachesForTesting, contains('fav'),
          reason: 'if the load is fire-and-forget, the first put can race it '
              'and enforce the cap against an empty pin set');
    });

    // REGRESSION (round 4, F3): round 2 moved file deletion to exact-keyed
    // lists, so the prefix-boundary test (which asserted via get()) silently
    // re-hydrated the collateral reach from disk and passed under a bare-prefix
    // mutant. The tiers where the collision still exists are memory and the
    // observers — assert there.
    test('evicting reach 1 leaves reach 10\'s observer alone', () async {
      final cache = newCache(cap: 2);
      await cache.initialize();

      await cache.put(_entryFor('1'));
      await cache.put(_entryFor('10'));
      final ten = cache.listenable(_keyFor('10'));
      void listener() {}
      ten.addListener(listener);
      expect(ten.value, isNotNull);

      await cache.put(_entryFor('2')); // evicts reach 1, the LRU

      expect(ten.value, isNotNull,
          reason: 'a bare-prefix evict nulls every observer sharing leading '
              'digits — the file tier can no longer collide, these tiers can');
      ten.removeListener(listener);
    });

    // REGRESSION (round 4, F4): the disk-hydration observer seed is the
    // mechanism behind "a stream you looked at earlier still draws instantly
    // with the network off" — a bound widget gets the disk value through it.
    test('a disk read seeds an already-bound observer', () async {
      final s1 = newCache();
      await s1.initialize();
      await s1.put(_entryFor('42'));

      final s2 = newCache();
      await s2.initialize();
      final bound = s2.listenable(_keyFor('42')); // bound BEFORE the read
      expect(bound.value, isNull, reason: 'nothing in memory yet');

      await s2.get(_keyFor('42'));

      expect(bound.value, isNotNull,
          reason: 'offline, the revalidation throws — this seed is the only '
              'way the cold-start disk value ever reaches the widget');
    });

    // REGRESSION (round 4, F6): a notifier can exist for a key that never
    // reached memory (watch() on an in-flight or failed fetch). Cap eviction
    // must release those too, or they are the unbounded remainder.
    test('cap eviction releases observers of never-cached keys', () async {
      final cache = newCache(cap: 1);
      await cache.initialize();

      // A watch on a key whose fetch never lands: notifier, no memory entry.
      cache.listenable(_keyFor('1', ForecastProduct.reachMetadata));
      await cache.put(_entryFor('1', ForecastProduct.shortRange));
      final before = cache.notifierCountForTesting;

      await cache.put(_entryFor('2')); // evicts reach 1's group

      expect(cache.notifierCountForTesting, lessThan(before),
          reason: 'the never-cached key\'s notifier belongs to the evicted '
              'group and nothing is listening — it must go with it');
    });

    // REGRESSION (round 5, F5): evict() was the one path that never dropped
    // the group's recency entry — the notifier map's growth shape, one path
    // over. No caller in lib/ yet; the first one must not inherit a leak.
    test('evicting a group\'s last product drops its recency entry', () async {
      final cache = newCache();
      await cache.initialize();
      await cache.put(_entryFor('1'));
      expect(cache.lastAccessCountForTesting, 1);

      await cache.evict(_keyFor('1'));

      expect(cache.lastAccessCountForTesting, 0);
    });

    // Round 8, F2: the observer reset on clear() and evict() was unguarded —
    // the existing evict test called listenable() AFTER the evict, asserting a
    // freshly-minted notifier's constructor rather than the eviction. Hold the
    // reference like a widget does.
    test('clear() nulls an observer a widget still holds', () async {
      final cache = newCache();
      await cache.initialize();
      await cache.put(_entryFor('1'));
      final held = cache.listenable(_keyFor('1'));
      void l() {}
      held.addListener(l);
      expect(held.value, isNotNull);

      await cache.clear();

      expect(held.value, isNull,
          reason: 'a held observer still showing the entry renders data the '
              'cache says does not exist');
      held.removeListener(l);
    });

    test('evict() nulls an observer a widget still holds', () async {
      final cache = newCache();
      await cache.initialize();
      await cache.put(_entryFor('1'));
      final held = cache.listenable(_keyFor('1'));
      void l() {}
      held.addListener(l);

      await cache.evict(_keyFor('1'));

      expect(held.value, isNull);
      held.removeListener(l);
    });

    // Round 4, F8: the sweep-skips-pins test cannot catch a rename that stays
    // self-consistent, so pin the one property that matters directly: the
    // name must not embed the ENTRY schema version, or every entry-format
    // bump deletes the pins (round 2's original bug).
    test('the pins filename is entry-version-free', () {
      expect(RiverDataCache.pinsFileNameForTesting, 'pins.json');
    });

    // REGRESSION (round 3, F3 — a defect inside round 2's own fix): a clear()
    // that is the session's FIRST cache op triggers init, whose persisted-pin
    // load resurrected the previous account's pins after clear() had zeroed
    // them. Reachable via the auth-state listener on a revoked-token cold
    // start. clear() now counts as this session's declaration.
    test('a first-op clear does not resurrect the previous account\'s pins',
        () async {
      final s1 = newCache();
      await s1.initialize();
      s1.setPinnedReaches({'oldUserFav'});
      await s1.put(_entryFor('oldUserFav'));

      final s2 = newCache(cap: 1);
      await s2.clear(); // FIRST op — init runs inside it
      await s2.put(_entryFor('oldUserFav')); // reach gets browsed again
      await s2.put(_entryFor('browse1'));

      expect(await s2.get(_keyFor('oldUserFav')), isNull,
          reason: 'the old account\'s pin must not rise from pins.json to '
              'shield its reach from the new session\'s cap');
    });

    // REGRESSION (round 3, F4): the FILES were bounded and the observer map
    // grew one entry per browsed key forever — guard 3's test counted
    // tempDir files, structurally blind to it.
    test('browsing does not grow the observer map without bound', () async {
      final cache = newCache(cap: 2);
      await cache.initialize();

      // One key is genuinely watched; the rest are drive-by browses.
      await cache.put(_entryFor('watched'));
      final watched = cache.listenable(_keyFor('watched'));
      void listener() {}
      watched.addListener(listener);

      for (var i = 0; i < 30; i++) {
        await cache.put(_entryFor('$i'));
      }

      expect(cache.notifierCountForTesting, lessThanOrEqualTo(2 * 2 + 1),
          reason: 'unwatched keys must release their notifiers on eviction — '
              'round 3 measured 59 notifiers over a 2-reach cap');
      // And the watched key keeps its OBJECT identity even after eviction —
      // handing the next listenable() caller a different notifier while the
      // widget holds the dead one is how a watch goes silently stale.
      expect(identical(cache.listenable(_keyFor('watched')), watched), isTrue);
      watched.removeListener(listener);
    });

    // REGRESSION (round 3, F5): put's disk write ran outside the serial
    // chain, so a fire-and-forget sign-out clear() racing it deleted the file
    // while memory kept the entry — an in-memory ghost gone at next restart.
    test('a put after an unawaited clear survives the restart', () async {
      final cache = newCache();
      await cache.initialize();
      await cache.put(_entryFor('x'));

      final clearing = cache.clear(); // sign-out does not await
      await cache.put(_entryFor('fresh'));
      await clearing;

      final s2 = newCache();
      await s2.initialize();
      expect(await s2.get(_keyFor('fresh')), isNotNull,
          reason: 'the put was ordered after the clear; its file must exist '
              'on disk, not just in the dead session\'s memory');
    });

    // Round 1, F10 adjunct: clear() drops the pins with the data.
    test('clear() drops the pins too', () async {
      final cache = newCache(cap: 1);
      await cache.initialize();
      cache.setPinnedReaches({'a'});
      await cache.clear();

      await cache.put(_entryFor('a'));
      await cache.put(_entryFor('b'));

      expect(await cache.get(_keyFor('a')), isNull,
          reason: 'pins belong to the account that declared them; surviving '
              'clear() shields the previous user\'s reaches from the next');
    });
  });
}

/// Phase 5 guard 9, 2026-08-29.
///
/// The kill switch evicts a favourite's entries so the live path takes over.
/// `put` puts its disk write on the cache's serial chain; `evict` deleted the
/// file OUTSIDE it. So a write already queued ran after the delete and put the
/// entry straight back — memory clean, disk dirty — and the next cold start
/// served the resurrected value with the switch off, making zero upstream
/// calls. Found on a device; eight review rounds had not.
void guard9EvictOrderingTests() {
  late Directory tempDir;

  const key = RiverDataKey(
    source: ForecastSource.nwm,
    reachId: '18471070',
    product: ForecastProduct.analysisAssimilation,
  );

  RiverDataEntry entry() => RiverDataEntry(
        key: key,
        window: FreshnessWindow(
          fetchedAt: DateTime.utc(2026, 8, 29, 4, 20),
          validUntil: DateTime.utc(2026, 8, 29, 5, 30),
        ),
        unit: 'CFS',
        payload: const {'currentFlow': 16702.1},
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('rivr_guard9');
  });
  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('guard 9: an evict cannot be undone by a write already queued', () {
    test('a put in flight when evict runs does not survive it', () async {
      final cache = RiverDataCache(cacheDirProvider: () async => tempDir);

      // The store listener's ingest is in flight...
      final pending = cache.put(entry());
      // ...when the kill switch evicts.
      final eviction = cache.evict(key);
      await Future.wait([pending, eviction]);

      expect(await cache.get(key), isNull,
          reason: 'memory still holds the evicted entry');

      // The one that actually mattered: a cold start reads DISK.
      final afterRestart =
          RiverDataCache(cacheDirProvider: () async => tempDir);
      expect(await afterRestart.get(key), isNull,
          reason: 'the entry came back from disk after a restart — this is '
              'the kill switch failing exactly as it did on the device');
    });

    test('an ordinary evict still removes the file', () async {
      final cache = RiverDataCache(cacheDirProvider: () async => tempDir);
      await cache.put(entry());
      expect(await cache.get(key), isNotNull);

      await cache.evict(key);

      final afterRestart =
          RiverDataCache(cacheDirProvider: () async => tempDir);
      expect(await afterRestart.get(key), isNull);
    });
  });
}
