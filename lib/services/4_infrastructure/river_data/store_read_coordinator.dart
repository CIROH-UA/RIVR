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
  /// tests passed. Rather than add a test that asserts a call was made, the
  /// call is now impossible to omit: you cannot build one without the thing it
  /// follows.
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
  Future<void> sync() async {
    if (_disposed) return;

    if (!_switch.isStoreReadEnabled) {
      // UNCONDITIONAL. Round 3, B3: guarding this on `_subs.isSubscribed`
      // meant a flip landing during the gap inside a sync — where the old
      // listeners are cancelled and the new ones not yet installed — detached
      // nothing, and the in-flight sync then installed listeners with the
      // switch off. detach() now runs through the same lock as sync, so it
      // waits for that sync and tears down what it built.
      //
      // detach, NOT dispose: the switch must be able to turn back ON without
      // an app restart, and dispose is terminal.
      AppLogger.info(_tag, 'kill switch off; detaching from the store');
      await _subs.detach();
      await _evictStoreEntries();
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

  /// Drop every cached entry the store could have written.
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
  Future<void> _evictStoreEntries() async {
    final keys = <RiverDataKey>[];
    for (final f in _favourites()) {
      for (final p in kStoredProducts[f.source] ?? const <ForecastProduct>[]) {
        keys.add(
          RiverDataKey(source: f.source, reachId: f.reachId, product: p),
        );
      }
    }
    if (keys.isEmpty) return;
    for (final k in keys) {
      try {
        await _cache.evict(k);
      } catch (e) {
        AppLogger.warning(_tag, 'could not evict ${k.storageKey}: $e');
      }
    }
    AppLogger.info(
      _tag,
      'kill switch off; evicted ${keys.length} store-written entries so the '
      'live path takes over immediately',
    );
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
