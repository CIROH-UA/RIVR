// lib/services/4_infrastructure/river_data/store_read_coordinator.dart
//
// ADR 0011 Phase 5: the one place that decides whether this device reads the
// store, and for which reaches.
//
// It exists so that decision lives in a single, testable object rather than
// being spread across a provider, a service and a widget. Three inputs:
//
//   the kill switch  — may this device read the store at all?
//   the favourites   — which reaches?
//   the subscription — attach and detach accordingly.
//
// **Turning the switch OFF must actively detach**, not merely stop subscribing.
// A device that already holds listeners would otherwise keep ingesting after
// being told to stop, which is the opposite of a kill switch. The ADR is blunt
// about why this matters: an app release takes days, so if the store serves
// something wrong the remedy has to work on devices already running.

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart';

import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/river_data/forecast_product.dart';
import 'package:rivr/models/1_domain/shared/river_data/river_data_key.dart';
import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_cache.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_read_switch.dart';
import 'package:rivr/services/4_infrastructure/river_data/store_subscription_service.dart';

/// The favourites this coordinator needs, narrowed to what it actually reads.
///
/// Deliberately not `FavoritesProvider`: the coordinator has no business
/// knowing about display names, images or refresh state, and narrowing the
/// input is what makes it testable without building a provider.
typedef FavouriteReachesReader = List<({ForecastSource source, String reachId})>
    Function();

class StoreReadCoordinator {
  /// Constructing this ATTACHES it. There is deliberately no un-attached
  /// state.
  ///
  /// Review round 3 deleted `..attach(_favorites)` from main.dart as a
  /// mutation — leaving the coordinator built but following nothing, so no
  /// listener was ever created and the whole phase was inert — and all 1136
  /// tests passed. Folding attach into the constructor closes THAT: you cannot
  /// build one that follows nothing.
  ///
  /// **It does not close the level above.** Round 4 pointed out that the
  /// CONSTRUCTION in `main.dart` is still omissible and still unguarded —
  /// deleting it leaves the suite green. Testing that requires pumping the
  /// root widget, which needs an initialised Firebase app, so it is covered by
  /// the device verification rather than by a unit test. Recorded here rather
  /// than claimed closed: an earlier version of this comment said the call was
  /// "impossible to omit", which was true of attach and false of the thing
  /// that calls it.
  StoreReadCoordinator({
    required StoreSubscriptionService subscriptions,
    required StoreReadSwitch readSwitch,
    required FavouriteReachesReader favourites,
    required IRiverDataCache cache,
    required Listenable favouritesListenable,
  })  : _subs = subscriptions,
        _switch = readSwitch,
        _favourites = favourites,
        _cache = cache {
    _attach(favouritesListenable);
  }

  static const String _tag = 'STORE_COORD';

  final StoreSubscriptionService _subs;
  final StoreReadSwitch _switch;
  final FavouriteReachesReader _favourites;
  final IRiverDataCache _cache;

  Listenable? _source;
  bool _disposed = false;
  bool _listeningToSwitch = false;

  /// Whether the store was reading in the PREVIOUS state, so eviction happens
  /// on the ON -> OFF transition and nowhere else.
  ///
  /// Round 4, B1: eviction was unconditional whenever the switch read false —
  /// and false is the DEFAULT, and `store_read_enabled` does not exist in
  /// Remote Config yet, so this was the shipping path. `FavoritesProvider`
  /// notifies from eleven places, at least three times per launch, and each
  /// one wiped every favourite's entries from memory AND disk. That is not a
  /// no-op: favourites are the PINNED reaches ADR 0011 Phase 2 exists to
  /// protect, so the phase made the app fetch MORE than before it, and an
  /// offline launch lost the last-known values for exactly the reaches the
  /// user cares about. A fix from round 3 that shipped a worse regression
  /// than the defect it closed.
  bool? _storeWasActive;

  /// Survives a relaunch, so a device that WAS reading the store still
  /// reclaims after a force-quit rather than serving poisoned entries from
  /// disk until they expire — up to 30 days for names and thresholds.
  static const String _prefsWasActive = 'adr0011_store_was_active';

  /// Serialises [sync]. Round 5, B3: `sync()` had no lock at all, and round
  /// 4's own fix put an `await _setActive(true)` — a SharedPreferences
  /// platform round-trip on a real device — in front of `syncFavourites`. A
  /// switch flip landing in that window (which is precisely what Remote
  /// Config's late `fetchAndActivate` does at launch) left the app subscribed
  /// with the switch OFF, with nothing to correct it until the next favourites
  /// change. Same shape as round 3's B3 and round 4's B2, one layer up,
  /// reopened by the fix for the layer below.
  Future<void> _pending = Future<void>.value();

  /// Whether the store is currently being read on this device.
  bool get isActive => _subs.isSubscribed;

  void _attach(Listenable source) {
    if (_disposed) return;
    _source = source;
    source.addListener(_onChanged);

    // Also follow the switch itself. Round 1, B2/B4: attaching happens at
    // startup while Remote Config is still resolving, so the switch reads
    // false here almost every time. Without this the store activated only if a
    // favourites change happened to arrive after RC resolved — order-dependent,
    // and when it lost, the feature was silently off for the whole session.
    // The same subscription is what lets a mid-session flip to false reach a
    // device that is already reading the store.
    if (!_listeningToSwitch) {
      _switch.changes.addListener(_onChanged);
      _listeningToSwitch = true;
    }

    unawaited(sync());
  }

  void _onChanged() => unawaited(sync());

  /// Reconcile subscriptions with the switch and the current favourites.
  ///
  /// Idempotent and safe to call as often as favourites change; the
  /// subscription service treats an unchanged set as a no-op.
  Future<void> sync() {
    final next = _pending.then((_) => _syncLocked());
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _syncLocked() async {
    if (_disposed) return;

    if (!_switch.isStoreReadEnabled) {
      // Detach UNCONDITIONALLY. Round 3, B3: guarding this on
      // `_subs.isSubscribed` meant a flip landing during the gap inside a
      // sync — where the old listeners are cancelled and the new ones not yet
      // installed — detached nothing, and the in-flight sync then installed
      // listeners with the switch off. detach() now runs through the same lock
      // as sync, so it waits for that sync and tears down what it built.
      //
      // detach, NOT dispose: the switch must be able to turn back ON without
      // an app restart, and dispose is terminal.
      await _subs.detach();

      // Evict ONLY on a real transition out of reading the store. See
      // [_storeWasActive] — doing this whenever the switch reads false meant
      // doing it constantly on the default configuration.
      // Do NOT reclaim on a value we cannot trust yet.
      //
      // `isStoreReadEnabled` is false both for "the operator turned this off"
      // and for "Remote Config has not resolved". Round 5 made the off-branch
      // keep its flag when it evicted nothing, which fixed a reclaim that
      // never fired — and created a worse one. Round 6 (Phase 8 re-review)
      // reproduced it: with the flag kept, a device where the store is ENABLED
      // and was never turned off can reach this branch on an ordinary launch
      // if favourites happen to load before Remote Config resolves, and then
      // evicts every favourite's entries from memory and disk. Before round 5
      // that was impossible only because the flag was consumed (uselessly) at
      // attach.
      //
      // Eviction is a destructive act taken on the operator's behalf. It waits
      // for the operator's actual decision. `initialize()` announces when it
      // resolves, which re-enters this method.
      if (!_switch.isResolved) {
        AppLogger.info(
          _tag,
          'switch not resolved yet; deferring any reclaim',
        );
        return;
      }

      if (await _wasActive()) {
        AppLogger.info(_tag, 'kill switch off; detaching and reclaiming');
        final evicted = await _evictStoreEntries();

        // Consume the flag ONLY if we actually reclaimed something.
        //
        // Round 5 (Phase 8 review): this used to clear it unconditionally, and
        // that made the cross-launch reclaim a no-op on nearly every install.
        // `_attach` runs at startup while Remote Config is still resolving —
        // the comment above `_attach` says the switch "reads false here almost
        // every time" — so this branch is taken on an ordinary launch. At that
        // instant `FavoritesProvider` has not loaded, `_favourites()` is empty,
        // `_evictStoreEntries` returns having evicted nothing, and clearing the
        // flag here meant the reclaim could never fire again for that install.
        //
        // The consequence is the exact failure the persistence exists to
        // prevent: flip the switch OFF, force-quit, relaunch, and
        // store-written `reachMetadata` and `returnPeriods` survive their full
        // 30-day window instead of being reclaimed.
        //
        // Leaving the flag set costs one extra attempt on the next sync —
        // which `_onChanged` fires as soon as favourites arrive — and that
        // attempt has the favourites it needs.
        if (evicted > 0) {
          await _setActive(false);
          _storeWasActive = false;
        } else {
          AppLogger.info(
            _tag,
            'nothing to reclaim yet (favourites not loaded); keeping the '
            'flag so the next sync retries',
          );
        }
        return;
      }
      _storeWasActive = false;
      return;
    }

    await _setActive(true);

    // Re-read AFTER the await. The value that mattered is the one true when we
    // actually subscribe, not the one true when we were called.
    if (!_switch.isStoreReadEnabled) {
      AppLogger.info(_tag, 'switch flipped off mid-sync; not subscribing');
      await _subs.detach();
      return;
    }

    final keys = [
      for (final f in _favourites())
        RiverDataKey(
          source: f.source,
          reachId: f.reachId,
          // Any product: the subscription watches every product the store
          // holds for this reach and ignores the one named here.
          product: f.source == ForecastSource.geoglows
              ? ForecastProduct.geoglowsForecast
              : ForecastProduct.shortRange,
        ),
    ];
    await _subs.syncFavourites(keys);
  }

  /// Drop every cached entry for a favourite, across every product the store
  /// holds.
  ///
  /// This deliberately evicts entries the LIVE path may have written too.
  /// There is no provenance marker on a cache entry, and the switch means
  /// "the store may have poisoned this" — so reclaiming a little too much and
  /// paying a refetch is the correct price, while reclaiming too little
  /// leaves the wrong number on screen. It runs only on the ON -> OFF
  /// transition, which is what makes that price affordable.
  ///
  /// Round 3, B2: detaching stops NEW ingests but reclaims nothing. Entries
  /// the listener already put in the shared cache stay there, and
  /// `RiverDataRepository.read` serves them as fresh with no source call — for
  /// up to an hour for the flow products and **thirty days** for the river
  /// name and the flood thresholds. So a store serving a wrong threshold
  /// survived the kill switch by a month, while this class's own comment
  /// promised every open app returns to the live path "within seconds".
  ///
  /// Evicting forces the next read down the live path, which is exactly what
  /// the switch means. It costs a refetch per favourite — the correct price
  /// for "the store is serving something wrong".
  Future<bool> _wasActive() async {
    if (_storeWasActive != null) return _storeWasActive!;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefsWasActive) ?? false;
    } catch (e) {
      // Never reached in production; in tests without the plugin this keeps
      // the safe answer, which is "do not evict".
      return false;
    }
  }

  Future<void> _setActive(bool value) async {
    if (_storeWasActive == value) return;
    _storeWasActive = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsWasActive, value);
    } catch (e) {
      AppLogger.warning(_tag, 'could not persist store-active flag: $e');
    }
  }

  /// Evict every entry the store could have written for a favourite.
  ///
  /// Returns how many keys were evicted, so the caller can tell "there was
  /// nothing to do" from "we have not loaded the favourites yet" — a
  /// distinction that decided whether the kill switch's reclaim worked at all.
  Future<int> _evictStoreEntries() async {
    final keys = <RiverDataKey>[];
    for (final f in _favourites()) {
      for (final p in kStoredProducts[f.source] ?? const <ForecastProduct>[]) {
        keys.add(
          RiverDataKey(source: f.source, reachId: f.reachId, product: p),
        );
      }
    }
    if (keys.isEmpty) return 0;
    for (final k in keys) {
      try {
        await _cache.evict(k);
      } catch (e) {
        AppLogger.warning(_tag, 'could not evict ${k.storageKey}: $e');
      }
    }
    AppLogger.info(
      _tag,
      'kill switch off; evicted ${keys.length} favourite entries so the live '
      'path takes over immediately',
    );
    return keys.length;
  }

  /// Release every listener but stay usable.
  ///
  /// For `AppLifecycleState.detached`, which is RESUMABLE on Android. Using
  /// the terminal [dispose] there killed the shared subscription singleton for
  /// the rest of the process (round 5, B2).
  Future<void> release() async {
    if (_disposed) return;
    await _subs.detach();
  }

  /// Detach from the favourites source and drop every listener (guard 6).
  Future<void> dispose() async {
    _disposed = true;
    _source?.removeListener(_onChanged);
    _source = null;
    if (_listeningToSwitch) {
      _switch.changes.removeListener(_onChanged);
      _listeningToSwitch = false;
    }
    await _subs.dispose();
  }
}
