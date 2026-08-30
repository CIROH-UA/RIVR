// lib/services/4_infrastructure/river_data/store_subscription_service.dart
//
// ADR 0011 Phase 5: the read path. Favourited reaches are served from the
// cloud store instead of upstream.
//
// **This is delivery, not fetching.** The app subscribes to its favourites'
// documents with a Firestore snapshot listener and pushes whatever arrives into
// the repository via `ingest`, so a server write reaches an open app without
// the app asking (guard 5) and warms Firestore's local cache for the next cold
// start.
//
// **It is NOT what makes guard 1 hold.** An earlier version of this comment
// said the opposite — that an ingested entry lands in the shared cache and
// `RiverDataRepository.read` therefore finds it fresh and makes no network
// call, so "guard 1 falls out of the existing freshness logic". Review round 2
// showed that cannot be true: `read` ALSO revalidates upstream on a stale
// entry and fetches on a miss, and nothing arbitrated whether an ingest or the
// favourites refresh landed first. Guard 1 is held by
// [StoreBackedDataSource], which moves the decision to where the upstream call
// actually happens. Round 3, B1: the two claims sat in one commit,
// contradicting each other.
//
// Three properties come free from Firestore's local persistence, which is on by
// default on iOS and Android:
//   - a WARM cold start renders from disk before any network round-trip
//     (guard 3) — warm meaning local persistence already holds the document;
//     a first install does not, which is why StoreBackedDataSource falls back
//     to a server read rather than to upstream
//   - with the network off, favourites still render (guard 4)
//   - a server write reaches an open app without the app asking (guard 5)
//
// **The app has no listeners today.** Lifecycle is new ground and a real leak
// and billing risk — an orphaned listener keeps billing reads forever — so
// every subscription is tracked and cancelled, and `dispose` is not optional.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_entry.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// The Firestore collection the ADR 0011 store writes to.
///
/// Must match `STORE_COLLECTION` in functions/src/store-keys.ts and the rule in
/// firestore.rules. A mismatch is denied by the rules, silently, forever.
const String kStoreCollection = 'river_data';

/// Products the store actually holds, per source.
///
/// A subset of each source's `supportedProducts`: the server only writes what
/// it can fetch on a publish cycle. Subscribing to a product the store never
/// writes costs a listener that can never fire.
const Map<ForecastSource, List<ForecastProduct>> kStoredProducts = {
  ForecastSource.nwm: [
    ForecastProduct.currentFlow,
    ForecastProduct.shortRange,
    ForecastProduct.mediumRange,
    ForecastProduct.longRange,
    // The near-static pair. Not decoration: guard 1 is "a favourite renders
    // with ZERO upstream calls from the device", and every surface that
    // renders a favourite reads the river's NAME and its flood THRESHOLDS.
    // Subscribing only to the flow products keeps the numbers fresh while
    // each favourite still makes two device-side calls just to draw itself —
    // the store present, the guard unreachable. Phase 5 review round 1.
    //
    // Written by the daily `storeStaticDaily` pass, not the hourly cycle
    // (they hold a 30-day window and carry no run to advance), and by
    // write-through the moment a reach is favourited.
    ForecastProduct.reachMetadata,
    ForecastProduct.returnPeriods,
  ],
  ForecastSource.geoglows: [
    ForecastProduct.geoglowsForecast,
  ],
};

/// Firestore's ceiling for `whereIn`. Document ids are queried in batches.
const int kWhereInBatchSize = 30;

/// Subscribes to the store for a set of reaches and feeds the repository.
class StoreSubscriptionService {
  StoreSubscriptionService({
    required IRiverDataRepository repository,
    FirebaseFirestore? firestore,
  })  : _repository = repository,
        _injectedDb = firestore;

  static const String _tag = 'STORE_SUB';

  final IRiverDataRepository _repository;
  final FirebaseFirestore? _injectedDb;

  /// Lazy, so constructing this does not require an initialised Firebase app.
  /// See the note on StoreReadSwitch._rc.
  FirebaseFirestore get _db => _injectedDb ?? FirebaseFirestore.instance;

  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> _subs = [];

  /// Document ids currently subscribed, so an unchanged favourite set is a
  /// no-op rather than a teardown and re-attach (which would re-bill every
  /// document read).
  Set<String> _watched = <String>{};

  /// Ingests dispatched from a snapshot and not yet finished.
  ///
  /// Tracked so [detach] can drain them. See the note in [_onSnapshot]: an
  /// ingest that outlives a detach re-writes exactly what the kill switch
  /// evicted.
  final Set<Future<void>> _inFlightIngests = <Future<void>>{};

  bool _disposed = false;

  /// Serialises [syncFavourites]. Round 1, B1: two calls entering across the
  /// `await _cancelAll()` gap both saw the OLD `_watched`, both subscribed, and
  /// both appended to `_subs` — permanently duplicating every listener for the
  /// session, so each server write was ingested N times and billed N times.
  /// Two favourite changes in one turn is enough (each ends in
  /// notifyListeners), and swipe-deleting two cards does it.
  Future<void> _pending = Future<void>.value();

  /// The last set [syncFavourites] was asked for, so a listener that dies can
  /// re-subscribe to it without waiting for the user to touch a favourite.
  Iterable<RiverDataKey> _lastRequested = const [];

  /// Consecutive listener failures, to bound the self-heal. Reset on a
  /// successful subscribe.
  int _consecutiveErrors = 0;

  /// Backoff for the self-heal. Bounded and short: the failure this recovers
  /// from is a token refresh racing a sign-in, which settles in seconds. After
  /// the last delay it stops and waits for a favourites change or a switch
  /// flip, because a PERMISSION_DENIED that survives 40s is a rules problem
  /// that retrying will not fix.
  ///
  /// The bound is real only because [_consecutiveErrors] is reset when a
  /// SNAPSHOT arrives rather than when a subscribe call returns — see
  /// [_onSnapshot]. Resetting on subscribe made every delay read as the first
  /// one, so this comment described a ladder the code did not climb.
  static const List<Duration> _healDelays = [
    Duration(seconds: 2),
    Duration(seconds: 8),
    Duration(seconds: 30),
  ];

  Timer? _healTimer;

  /// Bumped by every detach/dispose. A heal armed before a detach carries the
  /// old generation and is refused when it fires.
  ///
  /// Round 4, B2: `_detachLocked` cancelled the heal timer BEFORE awaiting
  /// `_cancelAll()`, so a listener error delivered during that await armed a
  /// NEW timer the detach would never cancel — and `detach` did not clear
  /// `_lastRequested`. Two seconds later the service re-subscribed, with the
  /// kill switch off and nothing left to correct it, because the coordinator
  /// only re-syncs on a favourites change or a switch flip. The re-attached
  /// listener kept calling `ingest`, and the repository then served those
  /// entries as fresh WITHOUT consulting any source — so the decorator's
  /// switch check never ran. A genuine kill-switch bypass, and the third
  /// distinct race in this area.
  int _generation = 0;

  /// Documents ingested since construction. Exposed for the guards.
  int ingested = 0;

  /// Documents rejected as unreadable. Exposed for the guards.
  int rejected = 0;

  /// Consecutive listener failures, for the backoff tests. Reading it is the
  /// only way to assert that a healthy snapshot CLEARS the ladder rather than
  /// merely that a failing one climbs it.
  @visibleForTesting
  int get debugConsecutiveErrors => _consecutiveErrors;

  /// Whether anything is currently subscribed.
  bool get isSubscribed => _subs.isNotEmpty;

  /// The document ids currently watched.
  Set<String> get watchedIds => Set.unmodifiable(_watched);

  /// Every document id the store could hold for [reaches].
  static Set<String> documentIdsFor(Iterable<RiverDataKey> reaches) {
    final ids = <String>{};
    for (final r in reaches) {
      for (final p in kStoredProducts[r.source] ?? const <ForecastProduct>[]) {
        ids.add(
          RiverDataKey(source: r.source, reachId: r.reachId, product: p)
              .storageKey,
        );
      }
    }
    return ids;
  }

  /// Point the subscription at exactly [reaches].
  ///
  /// Safe to call whenever favourites change. An unchanged set does nothing —
  /// re-attaching would re-read every document and bill for it.
  ///
  /// **A CHANGED set re-subscribes everything, and that is a real cost.**
  /// Adding one favourite to 20 tears down and rebuilds all 4 batches: 126
  /// document reads where an incremental diff would bill 6. Accepted for now
  /// rather than hidden — at the ADR's current scale (a handful of developers
  /// and some BYU students) this is a few hundred reads a day against a
  /// 50,000/day free tier, and subscription bookkeeping keyed per batch is
  /// more machinery than the saving justifies today. Revisit before any real
  /// user growth; this is the first thing that stops being cheap. Named by
  /// review round 2 (non-blocking 3).
  ///
  /// [reaches] carries source + reachId; the product on each key is ignored,
  /// because the service subscribes to every product the store holds.
  Future<void> syncFavourites(Iterable<RiverDataKey> reaches) {
    _lastRequested = List.of(reaches);
    // Chain rather than run: whatever is already reconciling finishes before
    // the next reconciliation reads `_watched`.
    final next = _pending.then((_) => _syncLocked(reaches));
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _syncLocked(Iterable<RiverDataKey> reaches) async {
    if (_disposed) return;

    final wanted = documentIdsFor(reaches);
    if (_setEquals(wanted, _watched)) return;

    await _cancelAll();
    _watched = wanted;

    if (wanted.isEmpty) {
      AppLogger.info(_tag, 'no favourites; nothing subscribed');
      return;
    }

    final ids = wanted.toList();
    // The generation these listeners belong to. A snapshot delivered after a
    // detach carries a stale one and must not ingest — see [_onSnapshot].
    final gen = _generation;
    for (var i = 0; i < ids.length; i += kWhereInBatchSize) {
      final batch = ids.sublist(
        i,
        i + kWhereInBatchSize > ids.length ? ids.length : i + kWhereInBatchSize,
      );
      final batchIds = batch.toSet();
      late final StreamSubscription<QuerySnapshot<Map<String, dynamic>>> sub;
      sub = _db
          .collection(kStoreCollection)
          .where(FieldPath.documentId, whereIn: batch)
          .snapshots()
          .listen(
            (snap) => _onSnapshot(snap, gen),
            // A permission error or a missing index must degrade to the live
            // path, not surface to the user (guard 8). The repository still
            // fetches upstream on a cache miss.
            onError: (Object e, StackTrace s) =>
                _onListenerError(sub, batchIds, e),
          );
      _subs.add(sub);
    }
    AppLogger.info(
      _tag,
      'subscribed to ${wanted.length} documents in ${_subs.length} listener(s)',
    );
  }

  /// A listener died. Degrade to the live path and stay recoverable.
  ///
  /// Round 1, B5: without clearing `_watched` the failure is TERMINAL. The
  /// dead stream stayed in `_subs` and `_watched` kept its ids, so the next
  /// sync saw an equal set and early-returned — never re-subscribing for the
  /// rest of the session. Signing out and back in reproduces it: every
  /// listener hits PERMISSION_DENIED, dies, and the store is silently off with
  /// the same favourites showing.
  ///
  /// Round 2 added dropping the dead subscription itself. Leaving it in
  /// `_subs` made `isSubscribed` — and through it `StoreReadCoordinator`'s
  /// `isActive`, which the guards read — report true for a stream that is
  /// dead.
  void _onListenerError(
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>> sub,
    Set<String> batchIds,
    Object e,
  ) {
    AppLogger.error(
      _tag,
      'store listener failed; falling back to the live path',
      e,
    );
    _subs.remove(sub);
    unawaited(sub.cancel().catchError((Object _) {}));
    // Only THIS batch's ids. Round 5, non-blocking 3: clearing the whole set
    // meant one failing batch reported an empty watch set while the other
    // three were still live — and that same set is the `storeBackedIds` gate,
    // so every favourite's cold read fell to upstream until a heal landed.
    _watched = _watched.difference(batchIds);
    _scheduleHeal();
  }

  /// Re-subscribe after a listener death, without waiting for the user.
  ///
  /// Round 3, non-blocking 6: clearing `_watched` made the failure
  /// RECOVERABLE but nothing triggered the recovery, so a mid-session
  /// PERMISSION_DENIED with no favourites change and no switch flip left the
  /// store silently off until the user happened to touch a favourite.
  void _scheduleHeal() {
    if (_disposed || _lastRequested.isEmpty) return;
    final generation = _generation;
    if (_consecutiveErrors >= _healDelays.length) {
      AppLogger.warning(
        _tag,
        'listener failed ${_consecutiveErrors + 1}x; giving up until '
        'favourites or the kill switch change',
      );
      return;
    }
    final delay = _healDelays[_consecutiveErrors];
    _consecutiveErrors++;
    _healTimer?.cancel();
    _healTimer = Timer(delay, () {
      // A detach or dispose between arming and firing invalidates this heal.
      // Without the generation check, healing re-subscribes AFTER the kill
      // switch said stop.
      if (_disposed || generation != _generation) {
        AppLogger.info(_tag, 'heal cancelled; the watch was torn down');
        return;
      }
      if (_lastRequested.isEmpty) return;
      AppLogger.info(_tag, 're-subscribing after a listener failure');
      unawaited(syncFavourites(_lastRequested).catchError((Object _) {}));
    });
  }

  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap, int gen) {
    // Refuse anything from a superseded subscription.
    //
    // Round 8 / Phase 5 guard 9, found on a device and not in review: the kill
    // switch detaches and then evicts, but a snapshot already delivered starts
    // a FIRE-AND-FORGET ingest that could complete AFTER the eviction and
    // write the store's value straight back to disk. The next cold start then
    // served store data with the switch off, made zero upstream calls, and the
    // switch's promise that "every open app returns to the live path within
    // seconds" was false — for as long as the entry stayed fresh.
    if (gen != _generation) return;
    // Success is a snapshot FROM THE SERVER — not a subscribe call returning,
    // and not a snapshot from the local cache.
    //
    // Round 5, B1: the reset lived in `_syncLocked` right after `listen(...)`,
    // which runs synchronously, while Firestore delivers listen errors
    // asynchronously — so `_consecutiveErrors` was ALWAYS 0 when
    // `_scheduleHeal` read it. The 2nd and 3rd delays were unreachable and the
    // give-up branch was dead code, so a failing listener was re-created every
    // 2 seconds forever. Reachable on sign-out: `river_data` requires an
    // authenticated request, so any favourites notification while signed out
    // re-subscribes straight into PERMISSION_DENIED.
    //
    // Round 6 then pointed out that moving it here was not enough, because
    // Firestore with local persistence delivers a CACHED snapshot before
    // failing a query whose documents it already holds — which is exactly the
    // sign-out case — so the counter would reset on every re-subscribe and the
    // 2-second loop would return. A unit test confirmed it rather than leaving
    // it a hypothesis. Only a server snapshot proves the subscription is
    // actually healthy.
    if (!snap.metadata.isFromCache) _consecutiveErrors = 0;
    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.removed) continue;
      final entry = decodeDocument(change.doc.id, change.doc.data());
      if (entry == null) {
        rejected++;
        continue;
      }
      ingested++;
      // Fire and forget: ingest only writes the shared cache, and awaiting it
      // inside a snapshot callback would serialise delivery behind disk I/O.
      // Still fire-and-forget for delivery — awaiting inside a snapshot
      // callback would serialise delivery behind disk I/O — but TRACKED, so
      // detach can wait for it. Untracked, the write outlives the eviction
      // meant to undo it.
      late final Future<void> ingest;
      ingest = _repository.ingest(entry).catchError(
        (Object e) => AppLogger.error(_tag, 'ingest failed for ${change.doc.id}', e),
      ).whenComplete(() => _inFlightIngests.remove(ingest));
      _inFlightIngests.add(ingest);
      unawaited(ingest);
    }
  }

  /// Turn a stored document into an entry, or null when it cannot be trusted.
  ///
  /// Returns null rather than throwing for every failure mode. A bad document
  /// must cost that one product its store delivery and nothing else — the
  /// repository then falls through to the live path, which is guard 8.
  static RiverDataEntry? decodeDocument(
    String documentId,
    Map<String, dynamic>? data,
  ) {
    if (data == null) return null;
    try {
      // Guard 10 / ADR decision 14: an unrecognised schema is DISCARDED, never
      // parsed. A future server writing v2 must not be decoded by a v1 client
      // guessing at the shape.
      final schema = data['schema'];
      if (schema is! int || schema != RiverDataEntry.schemaVersion) {
        AppLogger.warning(
          _tag,
          'discarding $documentId: schema $schema != ${RiverDataEntry.schemaVersion}',
        );
        return null;
      }
      final entry = RiverDataEntry.fromJson(data);

      // The document id IS the cache key. If they disagree the server and
      // client have drifted, and ingesting would file the payload under the
      // wrong reach — worse than not ingesting at all.
      if (entry.key.storageKey != documentId) {
        AppLogger.warning(
          _tag,
          'discarding $documentId: contents say ${entry.key.storageKey}',
        );
        return null;
      }
      return entry;
    } catch (e) {
      AppLogger.warning(_tag, 'discarding unreadable document $documentId: $e');
      return null;
    }
  }

  Future<void> _cancelAll() async {
    // Swap the list out BEFORE awaiting. Iterating `_subs` across an await
    // while detach() or dispose() clears it throws "Concurrent modification
    // during iteration" — these paths run outside syncFavourites' lock, so
    // they genuinely interleave. Found by the kill-switch tests, which flip the
    // switch (triggering a sync) and detach in the same turn.
    final taken = List.of(_subs);
    _subs.clear();
    for (final s in taken) {
      await s.cancel();
    }
  }

  /// Drop every listener but stay usable (guard 6).
  ///
  /// Distinct from [dispose] on purpose. The kill switch turning OFF must
  /// release listeners AND leave the service able to resume when it turns back
  /// ON. Using the terminal [dispose] for that made the switch one-way: once
  /// off, the store never came back without an app restart, which is not a
  /// switch. Idempotent.
  /// Wait for every dispatched ingest to finish.
  ///
  /// Bounded: each ingest is one cache write. Failures are already swallowed
  /// by the catchError attached at dispatch, so this cannot throw.
  Future<void> _drainIngests() async {
    while (_inFlightIngests.isNotEmpty) {
      await Future.wait(_inFlightIngests.toList());
    }
  }

  Future<void> detach() {
    // Through the SAME lock as syncFavourites. Round 3, B3: detach ran outside
    // it, and `_syncLocked` awaits `_cancelAll()` before installing the new
    // listeners — so during that gap `_subs` is empty. A kill switch flipping
    // OFF in that window detached nothing and the in-flight sync then
    // installed listeners anyway, leaving the app ingesting with the switch
    // off and nothing left to correct it. Structurally round 1's B1, one layer
    // up.
    final next = _pending.then((_) => _detachLocked());
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _detachLocked() async {
    // Bump FIRST: anything armed from here on — including an error delivered
    // during the await below — carries a stale generation and is refused.
    _generation++;
    final had = _subs.isNotEmpty || _watched.isNotEmpty;
    _consecutiveErrors = 0;
    // Cleared so a heal that somehow survives has nothing to re-subscribe to.
    _lastRequested = const [];
    await _cancelAll();
    _watched = <String>{};
    // Drain before returning. The coordinator evicts as soon as this
    // completes, so an ingest still running here would land after the
    // eviction and undo it.
    await _drainIngests();
    // Cancelled AFTER the await, not before: an error arriving mid-cancel used
    // to arm a timer that the earlier cancel had already passed.
    _healTimer?.cancel();
    _healTimer = null;
    // Only when there was something to release. `_syncLocked` calls detach
    // UNCONDITIONALLY on every sync while the switch is off — which is correct,
    // and round 3's B3 explains why — but favourites notify often, so logging
    // regardless produced 136 identical lines in one session on a device and
    // buried the lines that mattered.
    if (had) {
      AppLogger.info(_tag, 'detached; listeners released, service still usable');
    }
  }

  /// Permanently stop. Nothing subscribes again after this. Idempotent.
  Future<void> dispose() async {
    // Set BEFORE awaiting: anything already queued on the lock sees it and
    // early-returns rather than installing listeners behind our back.
    _disposed = true;
    _lastRequested = const [];
    await detach();
    AppLogger.info(_tag, 'disposed');
  }

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
