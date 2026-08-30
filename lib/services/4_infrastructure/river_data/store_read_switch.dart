// lib/services/4_infrastructure/river_data/store_read_switch.dart
//
// ADR 0011 Phase 5's kill switch.
//
//   "A Remote Config flag forces every device back to the live path. The flood
//    pipeline already uses Remote Config this way, and an app release takes
//    days — if the store serves something wrong, the fix cannot wait on Apple."
//
// That last clause is the whole design constraint. If the store starts serving
// a wrong number, the remedy has to reach every device in seconds. Shipping a
// build does not; a Remote Config parameter does.
//
// **Defaults to OFF.** A device that has never successfully fetched — offline
// first launch, Firebase hiccup, a fetch slower than the timeout — takes the
// live path, which is exactly today's behaviour. The failure mode of this
// switch is "the app works as it did before", never "the app trusts a store it
// could not ask about".
//
// **But a value already activated is trusted, even when today's fetch fails.**
// Remote Config persists activated values across launches, and an earlier
// version of this class gated every read behind a `_ready` flag that was only
// set after a SUCCESSFUL fetch. That inverted guard 4: a user who was online
// yesterday with the store enabled, launching offline today, had the switch
// read false and rendered nothing from the store — the one circumstance the
// offline guard exists for. Round 2. `getBool` on a key that was never
// fetched already returns false, so the safe default costs no extra gate.
//
// **It does not call `setDefaults`.** `FloodTilesetService` initialises the
// same `FirebaseRemoteConfig.instance` from `main` at the same moment, and
// `setDefaults` REPLACES the defaults map rather than merging, so whichever
// landed second wiped the other's. Round 2, B6.

import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

class StoreReadSwitch {
  StoreReadSwitch({FirebaseRemoteConfig? remoteConfig})
      : _injected = remoteConfig;

  static const String _tag = 'STORE_SWITCH';

  /// Remote Config parameter. Set to `true` to let devices read the store;
  /// flip to `false` and every device with the app OPEN returns to the live
  /// path within seconds, via [changes] and Remote Config's real-time updates.
  /// A backgrounded or closed app picks the new value up on next launch.
  static const String keyStoreReadEnabled = 'store_read_enabled';

  /// Startup must never wait on the network — the same rule
  /// [FloodTilesetService] follows.
  static const Duration _fetchTimeout = Duration(seconds: 3);

  final FirebaseRemoteConfig? _injected;

  /// Resolved lazily, NOT in the constructor. Building the DI graph must not
  /// require an initialised Firebase app: `FirebaseRemoteConfig.instance`
  /// throws without one, so a constructor reference made
  /// `setupForecastDependencies()` unresolvable in any plain unit test — which
  /// is why the Phase 5 wiring went unguarded long enough for review round 3
  /// to delete it wholesale with every test still green.
  FirebaseRemoteConfig get _rc => _injected ?? FirebaseRemoteConfig.instance;

  StreamSubscription<RemoteConfigUpdate>? _updates;

  /// Fires whenever the switch's value may have changed, so a running app can
  /// react without waiting for a relaunch.
  ///
  /// Round 1, B2/B4: without this the switch only took effect on next launch,
  /// AND only if a favourites change happened to follow — so a flip to false
  /// never reached the devices it exists to rescue, and a Remote Config fetch
  /// that resolved after startup silently left the store off for the session.
  /// The comment above this class claimed "within seconds" while the code did
  /// nothing of the sort.
  final ChangeNotifier changes = ChangeNotifier();

  bool _resolved = false;

  /// Whether the switch's value can be TRUSTED as a decision yet.
  ///
  /// `isStoreReadEnabled` is `getBool`, which returns false both for "the
  /// operator turned this off" and for "we have not fetched yet". Those are
  /// very different facts and the difference used to be harmless, because the
  /// only consequence of reading false early was not subscribing — which the
  /// post-fetch announce then corrected.
  ///
  /// It stopped being harmless when the coordinator gained a reclaim that
  /// EVICTS on the off-branch. Acting on an unresolved false means throwing
  /// away good cached data on an ordinary launch of a device where the store
  /// is enabled and was never turned off. Round 6 (Phase 8 re-review) found
  /// exactly that, introduced by the previous round's fix.
  ///
  /// True once a fetch has completed, in either direction — a failed fetch
  /// still resolves, because Remote Config then serves the last activated
  /// value and that IS the operator's decision.
  bool get isResolved => _resolved;

  /// Whether devices may read the store.
  ///
  /// False until a fetch has activated a true value — `getBool` returns false
  /// for a key that was never fetched — and true thereafter, including on a
  /// later offline launch, because Remote Config persists activated values.
  /// See the note on trusting activated values at the top of this file.
  bool get isStoreReadEnabled => _rc.getBool(keyStoreReadEnabled);

  /// Fetch the current value. Safe to call repeatedly; never throws.
  Future<void> initialize() async {
    // Subscribed FIRST, and in its own try, so that a failed fetch cannot cost
    // us the listener. Previously both lived in one try with the listener
    // registered after `fetchAndActivate`, so a single failed launch-time
    // fetch left the switch unable to change for the rest of the session — in
    // BOTH directions. For a mechanism whose stated purpose is "the fix cannot
    // wait on Apple", that is the failure that matters most. Round 2.
    try {
      _updates ??= _rc.onConfigUpdated.listen(
        (update) async {
          if (!update.updatedKeys.contains(keyStoreReadEnabled)) return;
          try {
            await _rc.activate();
          } catch (e) {
            AppLogger.warning(_tag, 'activate after update failed: $e');
          }
          AppLogger.info(
            _tag,
            'switch changed live -> '
            '${isStoreReadEnabled ? "ENABLED" : "disabled"}',
          );
          _announce();
        },
        onError: (Object e) =>
            AppLogger.warning(_tag, 'config update stream failed: $e'),
      );
    } catch (e) {
      AppLogger.warning(_tag, 'could not subscribe to config updates: $e');
    }

    try {
      await _rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: _fetchTimeout,
        // Zero, deliberately. A kill switch that takes an hour to propagate is
        // not a kill switch. The request is tiny and Remote Config serves its
        // cached value while this is in flight, so nothing blocks.
        minimumFetchInterval: Duration.zero,
      ));
      // No setDefaults — see the note at the top of this file. A missing key
      // already reads as false, which is the default this switch wants.
      await _rc.fetchAndActivate();

      // The fetch itself is a change from whatever was read before, and it
      // resolves AFTER attach(). Without announcing it the store never
      // activated on a cold start unless a favourites change happened to
      // follow.
      _resolved = true;
      _announce();
      AppLogger.info(
        _tag,
        'store read ${isStoreReadEnabled ? "ENABLED" : "disabled"}',
      );
    } catch (e) {
      // Not rethrown. Failing to reach Remote Config means the app behaves
      // exactly as it did before Phase 5 — degraded to correct, not broken.
      // Any value activated by an earlier launch still stands.
      AppLogger.warning(
        _tag,
        'remote config fetch failed; keeping the last activated value: $e',
      );
      _resolved = true;
      _announce();
    }
  }

  void _announce() {
    // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
    changes.notifyListeners();
  }

  /// Stop listening for config changes.
  Future<void> dispose() async {
    await _updates?.cancel();
    _updates = null;
    changes.dispose();
  }
}
