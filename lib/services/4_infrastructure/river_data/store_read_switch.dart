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
// **Defaults to OFF.** A device that cannot reach Remote Config — offline first
// launch, Firebase hiccup, a fetch slower than the timeout — takes the live
// path, which is exactly today's behaviour. The failure mode of this switch is
// "the app works as it did before", never "the app trusts a store it could not
// ask about".

import 'package:firebase_remote_config/firebase_remote_config.dart';

import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

class StoreReadSwitch {
  StoreReadSwitch({FirebaseRemoteConfig? remoteConfig})
      : _rc = remoteConfig ?? FirebaseRemoteConfig.instance;

  static const String _tag = 'STORE_SWITCH';

  /// Remote Config parameter. Set to `true` to let devices read the store;
  /// flip to `false` and every device returns to the live path within seconds.
  static const String keyStoreReadEnabled = 'store_read_enabled';

  /// Startup must never wait on the network — the same rule
  /// [FloodTilesetService] follows.
  static const Duration _fetchTimeout = Duration(seconds: 3);

  final FirebaseRemoteConfig _rc;

  bool _ready = false;

  /// Whether devices may read the store. False until proven otherwise.
  bool get isStoreReadEnabled => _ready && _rc.getBool(keyStoreReadEnabled);

  /// Fetch the current value. Safe to call repeatedly; never throws.
  Future<void> initialize() async {
    try {
      await _rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: _fetchTimeout,
        // Zero, deliberately. A kill switch that takes an hour to propagate is
        // not a kill switch. The request is tiny and Remote Config serves its
        // cached value while this is in flight, so nothing blocks.
        minimumFetchInterval: Duration.zero,
      ));
      await _rc.setDefaults(const {keyStoreReadEnabled: false});
      await _rc.fetchAndActivate();
      _ready = true;
      AppLogger.info(
        _tag,
        'store read ${_rc.getBool(keyStoreReadEnabled) ? "ENABLED" : "disabled"}',
      );
    } catch (e) {
      // Not rethrown. Failing to reach Remote Config means the app behaves
      // exactly as it did before Phase 5 — degraded to correct, not broken.
      _ready = false;
      AppLogger.warning(
        _tag,
        'remote config unavailable; staying on the live path: $e',
      );
    }
  }
}
