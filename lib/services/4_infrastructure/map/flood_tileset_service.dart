// lib/services/4_infrastructure/map/flood_tileset_service.dart

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Which flood tileset to draw, and what date to tell the user it describes.
///
/// The nightly Cloud Run job publishes a new `rivr-flooded-YYYYMMDD` tileset
/// and then writes its id into Remote Config. A **dated** id is not cosmetic:
/// Mapbox caches tiles for 12 hours on device and states the CDN cache cannot
/// be broken, so reusing one id would show yesterday's colours to anyone who
/// already had them. A fresh id has no cache history.
///
/// Remote Config is the source of truth because it can be changed without an
/// App Store release — a kill switch, a rollback, or exposing lake artefacts
/// for the NWM/GEOGLOWS teams, all in seconds. That matters more than usual
/// while the Apple developer account is locked out.
class FloodTilesetService {
  FloodTilesetService({FirebaseRemoteConfig? remoteConfig})
      : _rc = remoteConfig ?? FirebaseRemoteConfig.instance;

  final FirebaseRemoteConfig _rc;

  static const String keyTilesetId = 'flood_tileset_id';
  static const String keyDataDate = 'flood_data_date';
  static const String keyShowLakes = 'flood_show_lake_reaches';

  /// How far back the app will look for a published tileset. Matches the
  /// build job's 3-day retention — beyond that nothing exists to find.
  static const int fallbackDays = 3;

  /// Startup must not wait on the network. If Remote Config cannot be reached
  /// in time the app uses the last value it cached, and failing that derives
  /// the id from today's date.
  static const Duration _fetchTimeout = Duration(seconds: 3);

  bool _ready = false;

  /// Fetch the current values. Safe to call more than once; never throws.
  Future<void> initialize() async {
    try {
      await _rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: _fetchTimeout,
        // Fetch on every launch. A new tileset lands once a day and the user
        // should see it immediately; the request is small and well inside the
        // free tier. Remote Config still serves its cached value while this
        // is in flight, so nothing blocks.
        minimumFetchInterval: Duration.zero,
      ));
      await _rc.setDefaults(const {
        keyTilesetId: '',
        keyDataDate: '',
        keyShowLakes: false,
      });
      await _rc.fetchAndActivate();
      _ready = true;
      AppLogger.info(
        'FloodTilesetService',
        'remote config: ${_rc.getString(keyTilesetId)} '
            '(${_rc.getString(keyDataDate)})',
      );
    } catch (e) {
      // Offline first launch, Firebase hiccup, anything — the fallbacks below
      // cover it. Deliberately not rethrown: no flood colours is a degraded
      // map, but a map.
      AppLogger.warning('FloodTilesetService', 'remote config unavailable: $e');
    }
  }

  /// The tileset to load.
  ///
  /// Remote Config first; if it has nothing, derive today's id locally. The
  /// derived id is a guess — if that day's build has not published, its tiles
  /// simply 404 and no colours draw, which is the correct failure. It is never
  /// wrong in the dangerous direction: it cannot show stale data as current.
  String get tilesetId {
    final fromConfig = _ready ? _rc.getString(keyTilesetId) : '';
    if (fromConfig.isNotEmpty) return fromConfig;
    return idForDate(DateTime.now().toUtc());
  }

  /// The date the data describes — the *older* of the two source dates, so the
  /// label never overstates freshness (the tileset mixes GEOGLOWS' daily run
  /// with whichever NOAA cycle was latest). Empty when unknown, in which case
  /// the UI should show nothing rather than guess.
  String get dataDate => _ready ? _rc.getString(keyDataDate) : '';

  /// Whether reaches lying inside lakes are drawn. Off for the public; on is
  /// a diagnostic view for people who need to see model artefacts.
  bool get showLakeReaches => _ready && _rc.getBool(keyShowLakes);

  /// `byu-hydroinformatics.rivr-flooded-YYYYMMDD` for [day].
  static String idForDate(DateTime day) {
    final d = day.toUtc();
    final stamp = '${d.year}'
        '${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}';
    return '${AppConfig.floodTilesetPrefix}-$stamp';
  }

  /// Candidate ids newest first, for a caller that wants to probe backwards
  /// when the derived id is not published yet.
  static List<String> fallbackIds({DateTime? from}) {
    final start = (from ?? DateTime.now()).toUtc();
    return List.generate(
      fallbackDays,
      (i) => idForDate(start.subtract(Duration(days: i))),
    );
  }
}
