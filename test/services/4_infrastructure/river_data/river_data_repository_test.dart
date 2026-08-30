// test/services/4_infrastructure/river_data/river_data_repository_test.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/freshness_window.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_source.dart';
import 'package:rivr/services/4_infrastructure/river_data/river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/river_data/narrow_nwm_payloads.dart';
import 'package:rivr/services/4_infrastructure/river_data/source_registry.dart';

/// In-memory [IRiverDataCache] so repository tests are isolated from disk /
/// path_provider (the real RiverDataCache is covered by its own test).
/// A cache whose reads take a turn of the event loop.
///
/// Review round 7: every existing ingest test awaits one ingest before
/// starting the next, so the serialisation chain in `ingest` could be deleted
/// with the suite green. The chain only matters when two ingests for the SAME
/// key overlap — then, without it, both read the old value before either
/// writes, and the OLDER run can land last, walking the value backwards past
/// the supersession check that exists to stop exactly that.
///
/// A synchronous fake cannot express that: the interleave needs `get` to
/// yield.
class _SlowReadCache extends _MemoryCache {
  @override
  Future<RiverDataEntry?> get(RiverDataKey key) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return super.get(key);
  }
}

class _MemoryCache implements IRiverDataCache {
  final Map<String, RiverDataEntry> _mem = {};
  final Map<String, ValueNotifier<RiverDataEntry?>> _notifiers = {};

  ValueNotifier<RiverDataEntry?> _n(RiverDataKey k) => _notifiers.putIfAbsent(
    k.storageKey,
    () => ValueNotifier(_mem[k.storageKey]),
  );

  @override
  Future<void> initialize() async {}
  @override
  bool get isReady => true;
  @override
  void setPinnedReaches(Set<String> reachIds) {}
  @override
  Future<RiverDataEntry?> get(RiverDataKey key) async => _mem[key.storageKey];
  @override
  Future<void> put(RiverDataEntry entry) async {
    _mem[entry.key.storageKey] = entry;
    _n(entry.key).value = entry;
  }

  @override
  ValueListenable<RiverDataEntry?> listenable(RiverDataKey key) => _n(key);
  @override
  Future<void> evict(RiverDataKey key) async {
    _mem.remove(key.storageKey);
    _notifiers[key.storageKey]?.value = null;
  }

  @override
  Future<void> clear() async {
    _mem.clear();
    for (final n in _notifiers.values) {
      n.value = null;
    }
  }
}

/// A source whose fetches are counted and whose freshness window is fixed by
/// [validFor], so freshness is driven entirely by the injected clock.
class _ControllableSource implements IRiverDataSource {
  _ControllableSource({required this.source, required this.validFor});

  @override
  final ForecastSource source;
  final Duration validFor;

  int fetchCount = 0;
  double nextValue = 1.0;

  /// The network is down. Guard: "a stream you looked at earlier still draws
  /// instantly with the network off" — round 1 found no test anywhere made a
  /// source throw, so the stale-serve-on-failed-revalidation path (the entire
  /// mechanism behind offline draw) was unguarded.
  bool offline = false;

  /// Payload override, for tests that decode the fetched entry for real.
  Map<String, dynamic>? nextPayload;

  /// A window the SOURCE already knows, as the cloud store supplies one.
  DateTime? nextValidUntil;

  /// The instant the SERVER fetched this value, as StoreBackedDataSource
  /// reports it. Null for a genuine live fetch, which really did happen now.
  DateTime? nextFetchedAt;

  @override
  Set<ForecastProduct> get supportedProducts => ForecastProduct.values.toSet();

  /// Every reachId `validUntil` was asked about.
  ///
  /// The repository has to hand its KEY's reach to the source. A fake that
  /// ignores the argument cannot tell a correct implementation from one that
  /// passes a constant, and since Phase 9 the answer depends on which reach it
  /// is — an island document computed as CONUS expires eleven times before new
  /// data can exist.
  final List<String> validUntilReaches = [];

  @override
  DateTime validUntil(ForecastProduct product, DateTime now,
      {required String reachId}) {
    validUntilReaches.add(reachId);
    return now.toUtc().add(validFor);
  }

  /// The model run the next fetch reports, when set.
  String? nextRunId;

  @override
  Future<SourceFetchResult> fetch(RiverDataKey key) async {
    fetchCount++;
    if (offline) throw Exception('network unreachable');
    return SourceFetchResult(
      validUntil: nextValidUntil,
      fetchedAt: nextFetchedAt,
      payload: nextPayload ?? {'value': nextValue},
      unit: 'CMS',
      runId: nextRunId,
    );
  }
}

class _StubUnit implements IFlowUnitPreferenceService {
  _StubUnit({required this.current});

  /// Mutable: guard 6's driveable input IS the preference changing mid-test.
  String current;
  @override
  String get currentFlowUnit => current;
  @override
  String getDisplayUnit() => current == 'CFS' ? 'ft³/s' : 'm³/s';
  @override
  double convertFlow(double v, String from, String to) {
    if (from == to) return v;
    if (from == 'CMS' && to == 'CFS') return v * 35.3147;
    if (from == 'CFS' && to == 'CMS') return v / 35.3147;
    return v;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  ingestSerialisationTests();
  const key = RiverDataKey(
    source: ForecastSource.nwm,
    reachId: '23021904',
    product: ForecastProduct.shortRange,
  );

  late _ControllableSource source;
  late _MemoryCache cache;
  late DateTime now;
  late RiverDataRepository repo;

  setUp(() {
    source = _ControllableSource(
      source: ForecastSource.nwm,
      validFor: const Duration(hours: 1),
    );
    cache = _MemoryCache();
    now = DateTime.utc(2026, 7, 10, 12, 0);
    repo = RiverDataRepository(
      cache: cache,
      registry: SourceRegistry([source]),
      clock: () => now,
    );
  });

  // ── ADR 0011 Phase 7: the signal behind the one indicator ────────────────
  //
  // Phase 7 takes the timestamps off the values, so the app can no longer let
  // a user judge freshness for themselves. `outOfSync` is the whole of what it
  // offers instead, and SyncStatusBanner does nothing but render it — so these
  // tests, not the widget's, are what decide whether the promise holds.
  //
  // The bar is deliberately narrow: NOT "offline", NOT "a fetch failed", but
  // "we served a value past its window and could not replace it".
  group('outOfSync — Phase 7 guards 2, 3 and 4', () {
    test('starts false: nothing has been served, nothing is suspect', () {
      expect(repo.outOfSync.value, isFalse);
    });

    test('a fresh cache hit never raises it', () async {
      await repo.read(key);
      now = now.add(const Duration(minutes: 30)); // still inside the 1h window
      await repo.read(key);
      expect(repo.outOfSync.value, isFalse,
          reason: 'in-window data is current; a warning here is noise');
    });

    // Guard 3, at the level that matters. A store frozen past its cycle looks
    // exactly like this on device: the window has ended, the value is still
    // served so the screen is not empty, and the refresh that should have
    // replaced it cannot.
    test('serving past the window with a failed refresh raises it', () async {
      await repo.read(key);
      now = now.add(const Duration(hours: 2)); // window has ended
      source.offline = true;

      final served = await repo.read(key);
      expect(served, isNotNull, reason: 'stale data is still shown, not hidden');

      // The revalidation is deliberately unawaited inside read().
      await Future<void>.delayed(Duration.zero);
      expect(repo.outOfSync.value, isTrue);
    });

    test('a later successful fetch clears it', () async {
      await repo.read(key);
      now = now.add(const Duration(hours: 2));
      source.offline = true;
      await repo.read(key);
      await Future<void>.delayed(Duration.zero);
      expect(repo.outOfSync.value, isTrue);

      source.offline = false;
      await repo.refresh(key);
      expect(repo.outOfSync.value, isFalse,
          reason: 'one success proves the app can reach current data again');
    });

    // The distinction the banner's copy depends on. Offline alone is not a
    // staleness claim: a phone in airplane mode looking at a forecast fetched
    // twenty minutes ago is looking at the current forecast.
    test('offline with everything in-window stays silent', () async {
      await repo.read(key);
      source.offline = true;
      now = now.add(const Duration(minutes: 30));

      await repo.read(key);
      await Future<void>.delayed(Duration.zero);
      expect(repo.outOfSync.value, isFalse);
    });

    // ── Found by the Phase 7 review, all three were live defects ───────────

    // BLOCKER 1. Store documents arrive through `ingest` from the Firestore
    // listener, never through `_doFetch`. With the flag cleared only on fetch,
    // a phone coming back from a tunnel got current data pushed to it,
    // repainted it, and kept the warning over the top — every later read found
    // the cache fresh and never fetched, so nothing cleared it.
    test('a pushed store document clears it', () async {
      await repo.read(key);
      now = now.add(const Duration(hours: 2));
      source.offline = true;
      await repo.read(key);
      await Future<void>.delayed(Duration.zero);
      expect(repo.outOfSync.value, isTrue);

      await repo.ingest(RiverDataEntry(
        key: key,
        window: FreshnessWindow(
          fetchedAt: now,
          validUntil: now.add(const Duration(hours: 1)),
        ),
        unit: 'CMS',
        runId: 'run-2',
        payload: const {'value': 9.0},
      ));

      expect(repo.outOfSync.value, isFalse,
          reason: 'the store just supplied current data for this very key');
    });

    // BLOCKER 2. A miss that fails does NOT mean an empty screen: the
    // favourites card renders `lastKnownFlow` out of SharedPreferences with no
    // age check. After a cache wipe — sign-out, or the kill switch flipping
    // ON to OFF — a failing fetch leaves yesterday's number on screen with
    // nothing to say so, now that the "1d ago" label is gone.
    // Phase 9 wiring. Not "does the window come out right" — the fake returns
    // a constant, so that would pass with any reach at all — but "is the key's
    // OWN reach what the source was asked about".
    test('the repository asks the source about the KEY\'s reach', () async {
      const island = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '800000010',
        product: ForecastProduct.shortRange,
      );
      source.validUntilReaches.clear();

      await repo.read(island);

      expect(source.validUntilReaches, contains('800000010'),
          reason: 'a hardcoded or defaulted reach here puts every island '
              'document back on the CONUS hour, invisibly');
      expect(source.validUntilReaches, isNot(contains(key.reachId)));
    });

    test('a failed fetch on a cache MISS raises it', () async {
      source.offline = true;
      await expectLater(repo.read(key), throwsA(anything));
      expect(repo.outOfSync.value, isTrue);
    });

    // SHOULD-FIX 4. The flag used to be one global latch: raised by whichever
    // key failed, cleared by ANY key succeeding. With favourites refreshing
    // concurrently that made it both flap and lie.
    test('one key succeeding does not clear another key\'s failure', () async {
      const other = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '99999999',
        product: ForecastProduct.returnPeriods,
      );

      await repo.read(key);
      now = now.add(const Duration(hours: 2));
      source.offline = true;
      await repo.read(key);
      await Future<void>.delayed(Duration.zero);
      expect(repo.outOfSync.value, isTrue);

      // A different river's product fetches fine.
      source.offline = false;
      await repo.read(other);

      expect(repo.outOfSync.value, isTrue,
          reason: 'the ORIGINAL key is still unresolved; a success elsewhere '
              'must not speak for it');

      // Resolving the original one does clear it.
      await repo.refresh(key);
      expect(repo.outOfSync.value, isFalse);
    });

    // Review FYI 7. Pull-to-refresh is the gesture that literally asks "is
    // this current?" — failing it silently on data past its window is the
    // worst possible moment to say nothing.
    test('a failed refresh on expired data raises it', () async {
      await repo.read(key);
      now = now.add(const Duration(hours: 2)); // past the window
      source.offline = true;

      await expectLater(repo.refresh(key), throwsA(anything));
      expect(repo.outOfSync.value, isTrue);
    });

    // ...but not when the value on screen is still in-window. The user has
    // lost nothing, and a warning here is the noise that gets the strip
    // ignored before the day it matters.
    test('a failed refresh on FRESH data stays silent', () async {
      await repo.read(key);
      now = now.add(const Duration(minutes: 10)); // still inside the window
      source.offline = true;

      await expectLater(repo.refresh(key), throwsA(anything));
      expect(repo.outOfSync.value, isFalse);
    });

    // ── Guard 3: a store frozen past its cycle ───────────────────────────
    //
    // The scenario the Phase 7 review found unguarded, and it needs no schema
    // change to catch. A stored document's `validUntil` is extended every hour
    // that upstream has not published, so it reads "fresh" indefinitely; but
    // `fetchedAt` is never moved by an extension, and past the product's hold
    // cap the SERVER stops extending and lets the document expire. The client
    // now stops vouching at the same instant, using the same constant.
    // The re-review's blocker, and the reason the two tests below it were not
    // enough on their own: they wrote the crafted entry straight into the fake
    // cache, which ASSERTS the premise (an old fetchedAt survives) rather than
    // proving it. Production violated exactly that premise — `_doFetch`
    // stamped `fetchedAt: now` on every value, including ones the SERVER had
    // fetched hours earlier, so the hold clock reset on every device read and
    // the guard could never fire on the one path it existed for.
    //
    // This test goes through a source shaped like StoreBackedDataSource: it
    // returns the server's window, both halves of it.
    test('a store-served value keeps the SERVER fetchedAt, not the read clock',
        () async {
      final serverFetchedAt = now.subtract(const Duration(hours: 14));
      source.nextFetchedAt = serverFetchedAt;
      source.nextValidUntil = now.add(const Duration(hours: 1));

      final entry = await repo.refresh(key);

      expect(entry!.window.fetchedAt, serverFetchedAt,
          reason: 'stamping the read clock here resets the hold clock on '
              'every device read, which is what stopped guard 3 firing');
      expect(repo.outOfSync.value, isTrue,
          reason: '14h-old water against a 6h cap: the indicator is the whole '
              'point of carrying the server fetchedAt across');
    });

    test('a genuine live fetch still stamps now', () async {
      // fetchedAt is null for a real live fetch, which really did happen now.
      final entry = await repo.refresh(key);
      expect(entry!.window.fetchedAt, now);
      expect(repo.outOfSync.value, isFalse);
    });

    test('an in-window value HELD past its cap raises it', () async {
      // shortRange holds for 6h. Fetch, then jump 7h with a window that a
      // frozen store would have kept extending.
      await repo.read(key);
      final held = (await cache.get(key))!;
      now = now.add(const Duration(hours: 7));
      await cache.put(RiverDataEntry(
        key: key,
        window: FreshnessWindow(
          fetchedAt: held.window.fetchedAt, // NEVER moved by an extension
          validUntil: now.add(const Duration(hours: 1)), // extended forward
        ),
        unit: held.unit,
        runId: held.runId,
        payload: held.payload,
      ));

      final served = await repo.read(key);
      expect(served, isNotNull,
          reason: 'the value is still shown — this is a warning, not a blank '
              'screen');
      expect(repo.outOfSync.value, isTrue,
          reason: 'the window says fresh, but nobody has refetched this water '
              'for longer than the server itself would stand behind');
      expect(source.fetchCount, 1,
          reason: 'and it must not turn into a network call: the window is '
              'still valid, so this is a claim about confidence, not a refetch');
    });

    test('an in-window value INSIDE its cap stays silent', () async {
      await repo.read(key);
      final held = (await cache.get(key))!;
      now = now.add(const Duration(hours: 3)); // inside shortRange's 6h
      await cache.put(RiverDataEntry(
        key: key,
        window: FreshnessWindow(
          fetchedAt: held.window.fetchedAt,
          validUntil: now.add(const Duration(hours: 1)),
        ),
        unit: held.unit,
        runId: held.runId,
        payload: held.payload,
      ));

      await repo.read(key);
      expect(repo.outOfSync.value, isFalse,
          reason: 'a held value inside its cap really is the newest that '
              'exists; warning here is the noise that gets the strip ignored');
    });

    // Round 3 mutation: replacing `_judge` with an unconditional
    // `_markConfirmed` in `_ingestLocked` — vouching for whatever the store
    // pushes, however old — compiled clean and left all 1256 tests green. The
    // only ingest test asserted the flag CLEARS, which that mutation satisfies
    // by construction. Nothing asserted ingest can RAISE it.
    test('a pushed store document that is already too old RAISES it',
        () async {
      // shortRange holds for 6h. The server fetched this 14h ago.
      await repo.ingest(RiverDataEntry(
        key: key,
        window: FreshnessWindow(
          fetchedAt: now.subtract(const Duration(hours: 14)),
          validUntil: now.add(const Duration(hours: 1)),
        ),
        unit: 'CMS',
        runId: 'run-old',
        payload: const {'value': 1.0},
      ));

      expect(repo.outOfSync.value, isTrue,
          reason: 'the store pushed water older than the server itself would '
              'stand behind; adopting it silently is the failure this guard '
              'exists for');
    });

    // Round 3 BLOCKER. A key entered the set on a failed fetch and left only
    // when that exact key was adopted again — which for a river tapped once
    // on the map never happens. The strip then sat over the favourites page
    // permanently, surviving pull-to-refresh, reconnecting and fresh store
    // documents, until the app was force-quit.
    test('a mark for a key nobody reads again decays', () async {
      const transient = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '55555555',
        product: ForecastProduct.reachMetadata,
      );

      source.offline = true;
      await expectLater(repo.read(transient), throwsA(anything));
      expect(repo.outOfSync.value, isTrue);

      // The user closes the sheet and never opens that river again. Time
      // passes and favourites keep refreshing normally.
      now = now.add(RiverDataRepository.unconfirmedTtl + const Duration(minutes: 1));
      source.offline = false;
      await repo.read(key);

      expect(repo.outOfSync.value, isFalse,
          reason: 'a reach nobody is looking at any more must not hold the '
              'warning open forever');
    });

    test('but a mark that keeps being re-raised does NOT decay', () async {
      await repo.read(key);
      now = now.add(const Duration(hours: 2));
      source.offline = true;
      await repo.read(key);
      await Future<void>.delayed(Duration.zero);
      expect(repo.outOfSync.value, isTrue);

      // Still failing well after the TTL, and still being read.
      now = now.add(RiverDataRepository.unconfirmedTtl + const Duration(minutes: 1));
      await repo.read(key);
      await Future<void>.delayed(Duration.zero);

      expect(repo.outOfSync.value, isTrue,
          reason: 'the decay must not silence a problem that is still live');
    });

    // ── Guard 4, closed: the client judges RUN AGE too ────────────────────
    //
    // THE incident, from the phone's side. On 2026-08-29 the store wrote
    // GEOGLOWS punctually every single day carrying a run a day old. Every
    // freshness check the app had said fine, because they all asked "how long
    // ago did we write?" and the answer was "minutes". The server alarms on
    // run age; until this the client had no notion of it, so the operational
    // alarm fired and the phone showed nothing at all.
    test('a punctually-written value carrying OLD water raises it', () async {
      source.nextFetchedAt = now.subtract(const Duration(minutes: 15));
      source.nextValidUntil = now.add(const Duration(hours: 1));
      // shortRange's run-age cap is 16h.
      source.nextRunId =
          now.subtract(const Duration(hours: 20)).toIso8601String();

      await repo.refresh(key);

      expect(repo.outOfSync.value, isTrue,
          reason: 'written 15 minutes ago and still 20 hours out of date — '
              'this is the shape that ran undetected for days, and the shape '
              'the phone could not see until guard 4 was closed');
    });

    test('a current run written just as recently stays silent', () async {
      source.nextFetchedAt = now.subtract(const Duration(minutes: 15));
      source.nextValidUntil = now.add(const Duration(hours: 1));
      source.nextRunId =
          now.subtract(const Duration(hours: 3)).toIso8601String();

      await repo.refresh(key);
      expect(repo.outOfSync.value, isFalse);
    });

    test('a run identity that cannot be read is never treated as stale',
        () async {
      // Never guess. An unreadable run is not evidence of anything.
      source.nextFetchedAt = now.subtract(const Duration(minutes: 5));
      source.nextValidUntil = now.add(const Duration(hours: 1));
      source.nextRunId = 'not-a-date';

      await repo.refresh(key);
      expect(repo.outOfSync.value, isFalse);
    });

    test('a pipe-joined run is judged by its OLDEST segment', () async {
      // Same choice the server makes: a payload spanning runs is only as
      // fresh as the oldest water in it.
      source.nextFetchedAt = now.subtract(const Duration(minutes: 5));
      source.nextValidUntil = now.add(const Duration(hours: 1));
      final old = now.subtract(const Duration(hours: 20)).toIso8601String();
      final fresh = now.subtract(const Duration(hours: 2)).toIso8601String();
      source.nextRunId = '$old|$fresh';

      await repo.refresh(key);
      expect(repo.outOfSync.value, isTrue,
          reason: 'judging by the newest segment would call this current');
    });

    test('it notifies listeners, so the banner can rebuild', () async {
      var notified = 0;
      repo.outOfSync.addListener(() => notified++);

      await repo.read(key);
      now = now.add(const Duration(hours: 2));
      source.offline = true;
      await repo.read(key);
      await Future<void>.delayed(Duration.zero);

      expect(notified, greaterThan(0));
    });
  });

  test('read miss fetches, caches, and returns the value', () async {
    final entry = await repo.read(key);
    expect(entry, isNotNull);
    expect(entry!.payload['value'], 1.0);
    expect(entry.unit, 'CMS');
    expect(source.fetchCount, 1);
  });

  test('read within the freshness window serves cache, no second fetch',
      () async {
    await repo.read(key);
    now = now.add(const Duration(minutes: 30)); // still < 1h
    final again = await repo.read(key);

    expect(source.fetchCount, 1);
    expect(again!.payload['value'], 1.0);
  });

  test('read past validUntil serves stale then revalidates in background',
      () async {
    await repo.read(key); // value 1.0, fetchCount 1
    now = now.add(const Duration(hours: 2)); // now stale
    source.nextValue = 2.0;

    final stale = await repo.read(key);
    expect(stale!.payload['value'], 1.0); // served stale immediately

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(source.fetchCount, 2); // background revalidation ran
    final refreshed = await cache.get(key);
    expect(refreshed!.payload['value'], 2.0);
    expect(cache.listenable(key).value!.payload['value'], 2.0);
  });

  test('concurrent reads on a cold key share one fetch', () async {
    final results = await Future.wait([repo.read(key), repo.read(key)]);
    expect(source.fetchCount, 1);
    expect(results.every((e) => e!.payload['value'] == 1.0), isTrue);
  });

  test('refresh always fetches, even when fresh', () async {
    await repo.read(key); // fetchCount 1
    source.nextValue = 5.0;
    final refreshed = await repo.refresh(key);

    expect(source.fetchCount, 2);
    expect(refreshed!.payload['value'], 5.0);
  });

  test('watch returns an observable that populates after read', () async {
    final listenable = repo.watch(key);
    expect(listenable.value, isNull);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(listenable.value, isNotNull);
    expect(listenable.value!.payload['value'], 1.0);
  });

  test('ingest inserts an externally-produced entry and notifies', () async {
    final pushed = RiverDataEntry(
      key: key,
      window: FreshnessWindow(
        fetchedAt: now,
        validUntil: now.add(const Duration(hours: 1)),
      ),
      unit: 'CMS',
      payload: const {'value': 99.0},
    );

    await repo.ingest(pushed);

    expect((await cache.get(key))!.payload['value'], 99.0);
    expect(cache.listenable(key).value!.payload['value'], 99.0);
    expect(source.fetchCount, 0); // no network involved
  });
  // ADR 0011 Phase 1 — the claim that "See forecast" is warm with nothing
  // warming it. The sheet and the forecast page were made to read the SAME
  // three narrow keys; that is only worth anything if the second surface
  // genuinely hits cache. Asserted rather than assumed, because the previous
  // design achieved warmth by an explicit background warm that also pulled a
  // 156 KB series and duplicated the entry.
  // ─── ADR 0011 Phase 2, guards 1 and 6 ─────────────────────────────────────

  group('entries record their run (ADR 0011 Phase 2 build line)', () {
    // Round 5 found the "entries record the run they came from" build line
    // unimplemented: the entry carried only a schedule window, so what a
    // revalidation brought back was not decidable from the stored data.
    test('the run id travels from source to cached entry', () async {
      source.nextRunId = '2026-08-23T12:00:00Z';

      final entry = await repo.read(key);

      expect(entry!.runId, '2026-08-23T12:00:00Z',
          reason: 'without it, two fetches of the same run are '
              'indistinguishable from a real update');
      // And it survives the JSON round-trip the disk tier uses.
      final rt = RiverDataEntry.fromJson(entry.toJson());
      expect(rt.runId, '2026-08-23T12:00:00Z');
    });

    // The no-run-identity case is guarded at the SOURCE layer
    // (data_sources_test: returnPeriods → null, GEOGLOWS fallback → null),
    // where the decision lives. A repository-level copy only pinned the
    // fake's default and was cut in round 7 as vacuous.
  });

  group('offline — a cached reach still draws with the network off', () {
    // The phase's "you are done when" names this outright, and round 1 proved
    // the whole 1019-test suite green with the revalidation made blocking and
    // throwing — offline would have shown a network error instead of the
    // cached river, and nothing could see it.
    test('a stale entry is served even though revalidation throws', () async {
      await repo.read(key); // fetch 1, cached
      now = now.add(const Duration(hours: 2)); // past the window
      source.offline = true;

      final got = await repo.read(key);

      expect(got, isNotNull,
          reason: 'the cached value is the only value there is — offline, '
              'stale-and-served beats fresh-and-thrown every time');
      expect(got!.payload['value'], 1.0);
      // Let the failed background revalidation settle.
      await Future<void>.delayed(Duration.zero);
      expect(source.fetchCount, 2,
          reason: 'the revalidation was attempted — offline serving must not '
              'come from skipping revalidation entirely');
    });

    test('a fresh entry offline is served without any attempt', () async {
      await repo.read(key);
      source.offline = true;

      final got = await repo.read(key);

      expect(got, isNotNull);
      expect(source.fetchCount, 1);
    });

    test('a cold miss offline propagates — there is nothing to serve',
        () async {
      source.offline = true;

      await expectLater(repo.read(key), throwsA(isA<Exception>()),
          reason: 'inventing data would be worse; the surfaces render their '
              'named error states from this');
    });
  });

  // Guard 1's "ONE background revalidation": the stale path shares the same
  // _inFlight dedup as the cold path, asserted here rather than inferred.
  test('concurrent stale reads share one revalidation', () async {
    await repo.read(key); // fetch 1
    now = now.add(const Duration(hours: 2)); // stale

    await Future.wait([repo.read(key), repo.read(key), repo.read(key)]);
    await Future<void>.delayed(Duration.zero);

    expect(source.fetchCount, 2,
        reason: 'three stale readers must fund ONE revalidate between them — '
            'the original fetch plus one, not plus three');
  });

  group('guard 1 — run supersession, not wall-clock', () {
    // "Tap → back → tap again issues nothing." The window encodes the next
    // possible publish, so inside it a re-read must cost zero fetches no
    // matter how much wall-clock time the entry has already survived.
    test('a wall-clock-old entry inside its run window fetches nothing',
        () async {
      await repo.read(key); // fetch 1, valid for 1 h
      // 55 minutes pass — old by any TTL habit, current by run schedule.
      now = now.add(const Duration(minutes: 55));

      await repo.read(key); // tap
      await repo.read(key); // back, tap again

      expect(source.fetchCount, 1,
          reason: 'the upstream run has not advanced; any refetch here is '
              'spend without information');
    });
  });

  group('guard 6 — a unit-preference change costs zero refetches', () {
    // The driveable input is the preference itself, flipped mid-test on ONE
    // mutable service — the shape the app actually produces (the settings page
    // mutates the singleton and surfaces re-render). Zero refetches falls out
    // structurally: the unit is not part of RiverDataKey, so the second read
    // resolves the identical entry; conversion happens at decode, per render.
    // Round 2 rejected a version that flipped nothing and asserted a property
    // two other tests already pinned.
    test('flipping the preference re-renders from the same entry, no fetch',
        () async {
      source.nextPayload = {
        'returnPeriods': [
          {'feature_id': '23021904', 'return_period_2': 100.0},
        ],
      };
      const rpKey = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '23021904',
        product: ForecastProduct.returnPeriods,
      );
      final unitService = _StubUnit(current: 'CMS');

      // Render #1 under CMS.
      final entry = await repo.read(rpKey);
      final before = ReturnPeriodPayload.decode(entry!, unitService);
      expect(before![2], 100.0);

      // The user flips the preference; the surface re-renders.
      unitService.current = 'CFS';
      final again = await repo.read(rpKey);
      final after = ReturnPeriodPayload.decode(again!, unitService);

      expect(source.fetchCount, 1,
          reason: 'the flip must cost zero fetches — the unit is not part of '
              'the key, so the cache cannot even distinguish the two reads');
      expect(identical(entry, again), isTrue,
          reason: 'literally the same cached entry, not a refetched copy');
      expect(after![2], closeTo(3531.47, 0.1),
          reason: 'and the re-render converts: same bytes, new preference');
    });
  });

  group('sheet -> forecast page is a cache hit', () {
    const products = [
      ForecastProduct.reachMetadata,
      ForecastProduct.analysisAssimilation,
      ForecastProduct.returnPeriods,
    ];

    RiverDataKey keyFor(ForecastProduct p) => RiverDataKey(
          source: ForecastSource.nwm,
          reachId: '23021904',
          product: p,
        );

    test('the forecast page issues zero fetches after the sheet has loaded',
        () async {
      // Sheet opens.
      for (final p in products) {
        await repo.read(keyFor(p));
      }
      final afterSheet = source.fetchCount;
      expect(afterSheet, products.length);

      // User taps "See forecast" — same keys.
      for (final p in products) {
        await repo.read(keyFor(p));
      }

      expect(source.fetchCount, afterSheet,
          reason: 'the page must not refetch what the sheet already holds');
    });

    test('the two surfaces receive the identical entry, not equal copies',
        () async {
      final fromSheet = await repo.read(keyFor(ForecastProduct.analysisAssimilation));
      source.nextValue = 999.0; // would differ if the page refetched
      final fromPage = await repo.read(keyFor(ForecastProduct.analysisAssimilation));

      expect(fromPage!.payload['value'], fromSheet!.payload['value'],
          reason: 'one cache entry per value is what stops the gauge and the '
              'sheet disagreeing');
      expect(fromPage.payload['value'], 1.0);
    });
  });

  // ── ADR 0011 Phase 5, review round 4 ─────────────────────────────────────

  group('B3 — ingest must not walk a value BACKWARDS', () {
    RiverDataEntry entryWith({
      required String? runId,
      required String tag,
      Duration validFor = const Duration(hours: 1),
    }) =>
        RiverDataEntry(
          key: key,
          window: FreshnessWindow(
            fetchedAt: now,
            validUntil: now.add(validFor),
          ),
          unit: 'CMS',
          runId: runId,
          payload: {'from': tag},
        );

    // The store's listener pushed straight into the cache with no ordering
    // check, while the SERVER refuses exactly this write (Phase 4 guard 6,
    // "overlapping runs cannot write backwards"). Two reachable orderings:
    // the initial snapshot on attach delivers every watched document while
    // FavoritesProvider's 500ms refresh-all routinely lands first; and between
    // :00 and :20 past the hour the store still holds the previous run.
    // The user watches the flow go backwards.
    test('an OLDER run does not replace a newer one', () async {
      await cache.put(entryWith(runId: '2026-07-10T12:00:00Z', tag: 'live-12'));

      await repo.ingest(
          entryWith(runId: '2026-07-10T11:00:00Z', tag: 'store-11'));

      final got = await cache.get(key);
      expect(got!.payload['from'], 'live-12',
          reason: 'the 11:00 run must not overwrite the 12:00 one');
    });

    test('a NEWER run does replace', () async {
      await cache.put(entryWith(runId: '2026-07-10T11:00:00Z', tag: 'live-11'));

      await repo.ingest(
          entryWith(runId: '2026-07-10T12:00:00Z', tag: 'store-12'));

      expect((await cache.get(key))!.payload['from'], 'store-12');
    });

    test('the SAME run is not rewritten', () async {
      await cache.put(entryWith(runId: '2026-07-10T12:00:00Z', tag: 'first'));

      await repo.ingest(entryWith(runId: '2026-07-10T12:00:00Z', tag: 'second'));

      expect((await cache.get(key))!.payload['from'], 'first',
          reason: 'same run means same data; rewriting churns observers');
    });

    test('losing run identity is refused', () async {
      await cache.put(entryWith(runId: '2026-07-10T12:00:00Z', tag: 'ident'));

      await repo.ingest(entryWith(runId: null, tag: 'anonymous'));

      expect((await cache.get(key))!.payload['from'], 'ident',
          reason: 'going from identified to unidentified loses the ability '
              'to order anything afterwards');
    });

    test('an empty cache accepts anything', () async {
      await repo.ingest(entryWith(runId: null, tag: 'first-ever'));
      expect((await cache.get(key))!.payload['from'], 'first-ever');
    });

    test('an EXPIRED ingest is refused', () async {
      // Ingesting one puts a value in the cache that read() immediately treats
      // as stale and revalidates upstream — a network call CAUSED by the
      // store, which is the opposite of the point.
      await repo.ingest(entryWith(
          runId: null, tag: 'expired', validFor: const Duration(hours: -1)));

      expect(await cache.get(key), isNull);
    });
  });

  group('B4/M4 — a source-supplied freshness window is honoured', () {
    // Without the passthrough every device re-stamps the SERVER's window from
    // its own read clock, so a 29-day-old river name is handed another 30 days
    // on every read, indefinitely. Round 4 deleted the passthrough as a
    // mutation and all 1146 tests still passed.
    test('the source window wins over the computed one', () async {
      final serverWindow = now.add(const Duration(days: 30));
      source.nextValidUntil = serverWindow;

      final entry = await repo.read(key);

      expect(entry!.window.validUntil, serverWindow,
          reason: 'the store fetched this earlier and its window must not be '
              'extended by the device that reads it');
    });

    test('without one, the publish schedule still applies', () async {
      source.nextValidUntil = null;

      final entry = await repo.read(key);

      expect(entry!.window.validUntil, now.add(const Duration(hours: 1)),
          reason: 'the live path must keep its publish-aligned window');
    });
  });
}

/// Review round 7 flagged the ingest serialisation as revertible with a green
/// suite: every other ingest test awaits one call before starting the next, so
/// the per-key chain never had to do anything. These overlap two ingests for
/// the same key, which is the only situation it exists for.
///
/// Reachable in production, and not rarely: the subscription service dispatches
/// every document in a snapshot with `unawaited(...)`, so a snapshot carrying
/// two runs of one reach — or a re-subscribe delivering the initial snapshot
/// while a previous batch is still ingesting — puts two ingests for the same
/// key in flight at once.
void ingestSerialisationTests() {
  const key = RiverDataKey(
    source: ForecastSource.nwm,
    reachId: '23021904',
    product: ForecastProduct.shortRange,
  );
  final now = DateTime.utc(2026, 7, 10, 12, 0);

  RiverDataEntry entryWith({required String runId, required String tag}) =>
      RiverDataEntry(
        key: key,
        window: FreshnessWindow(
          fetchedAt: now,
          validUntil: now.add(const Duration(hours: 1)),
        ),
        unit: 'CMS',
        runId: runId,
        payload: {'from': tag},
      );

  group('round 7 — concurrent ingests for one key are serialised', () {
    late _SlowReadCache cache;
    late RiverDataRepository repo;

    setUp(() {
      cache = _SlowReadCache();
      repo = RiverDataRepository(
        cache: cache,
        registry: SourceRegistry(const []),
        clock: () => now,
      );
    });

    test('an older run dispatched alongside a newer one cannot win', () async {
      // Both start before either finishes reading. Unserialised, both see an
      // empty cache, both pass the supersession check, and whichever writes
      // last wins — which is the older run half the time.
      await Future.wait([
        repo.ingest(entryWith(runId: '2026-07-10T12:00:00Z', tag: 'newer')),
        repo.ingest(entryWith(runId: '2026-07-10T11:00:00Z', tag: 'older')),
      ]);

      final got = await cache.get(key);
      expect(got!.payload['from'], 'newer',
          reason: 'the 11:00 run overwrote the 12:00 one — the supersession '
              'check cannot see a value the concurrent ingest has not '
              'written yet');
      expect(got.runId, '2026-07-10T12:00:00Z');
    });

    test('order of dispatch does not change the outcome', () async {
      await Future.wait([
        repo.ingest(entryWith(runId: '2026-07-10T11:00:00Z', tag: 'older')),
        repo.ingest(entryWith(runId: '2026-07-10T12:00:00Z', tag: 'newer')),
      ]);

      final got = await cache.get(key);
      expect(got!.runId, '2026-07-10T12:00:00Z');
    });

    test('three overlapping runs settle on the newest', () async {
      await Future.wait([
        repo.ingest(entryWith(runId: '2026-07-10T11:00:00Z', tag: 'a')),
        repo.ingest(entryWith(runId: '2026-07-10T13:00:00Z', tag: 'c')),
        repo.ingest(entryWith(runId: '2026-07-10T12:00:00Z', tag: 'b')),
      ]);

      final got = await cache.get(key);
      expect(got!.payload['from'], 'c');
    });

    test('different keys are NOT serialised against each other', () async {
      // The chain is per key on purpose: serialising everything would make one
      // slow reach hold up every other reach in a snapshot.
      const other = RiverDataKey(
        source: ForecastSource.nwm,
        reachId: '99999999',
        product: ForecastProduct.shortRange,
      );
      final started = DateTime.now();
      await Future.wait([
        repo.ingest(entryWith(runId: '2026-07-10T12:00:00Z', tag: 'one')),
        repo.ingest(RiverDataEntry(
          key: other,
          window: FreshnessWindow(
            fetchedAt: now,
            validUntil: now.add(const Duration(hours: 1)),
          ),
          unit: 'CMS',
          runId: '2026-07-10T12:00:00Z',
          payload: const {'from': 'two'},
        )),
      ]);
      final elapsed = DateTime.now().difference(started);
      expect(elapsed.inMilliseconds, lessThan(40),
          reason: 'two different keys ran back-to-back instead of in '
              'parallel — the chain is meant to be per key');
    });
  });
}
