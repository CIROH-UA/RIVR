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
  StoreReadCoordinator({
    required StoreSubscriptionService subscriptions,
    required StoreReadSwitch readSwitch,
    required FavouriteReachesReader favourites,
  })  : _subs = subscriptions,
        _switch = readSwitch,
        _favourites = favourites;

  static const String _tag = 'STORE_COORD';

  final StoreSubscriptionService _subs;
  final StoreReadSwitch _switch;
  final FavouriteReachesReader _favourites;

  Listenable? _source;
  bool _disposed = false;

  /// Whether the store is currently being read on this device.
  bool get isActive => _subs.isSubscribed;

  /// Begin following [source]'s changes (normally the favourites provider).
  ///
  /// Safe to call once. The listener is removed in [dispose].
  void attach(Listenable source) {
    if (_disposed) return;
    _source = source;
    source.addListener(_onChanged);
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
      // Not "skip subscribing" — actively let go of anything already held.
      if (_subs.isSubscribed) {
        // detach, NOT dispose: the switch must be able to turn back ON without
        // an app restart, and dispose is terminal.
        AppLogger.info(_tag, 'kill switch off; detaching from the store');
        await _subs.detach();
      }
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

  /// Detach from the favourites source and drop every listener (guard 6).
  Future<void> dispose() async {
    _disposed = true;
    _source?.removeListener(_onChanged);
    _source = null;
    await _subs.dispose();
  }
}
