// lib/services/4_infrastructure/network/connectivity_service.dart

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Whether the device can actually reach the internet.
///
/// `connectivity_plus` alone cannot answer that. It reports which **network
/// interface** is up, and its own documentation is explicit that this is not a
/// guarantee of connectivity. Airport wi-fi, a captive portal, a hotel splash
/// page and a dead router all present a live interface, which is exactly when a
/// user most needs to be told that nothing is loading.
///
/// So an interface is treated as necessary but not sufficient: when one is
/// present the service confirms with a small request before declaring the app
/// online. No interface at all is conclusive on its own and skips the probe.
class ConnectivityService {
  ConnectivityService._internal();
  static final ConnectivityService instance = ConnectivityService._internal();

  /// A 204-style endpoint: no body, no redirect, and — crucially — a captive
  /// portal cannot fake it. A portal intercepts the request and answers 200
  /// with its own login page, which fails the status check and correctly reads
  /// as offline.
  static final Uri _probeUrl = Uri.parse('https://clients3.google.com/generate_204');
  static const Duration _probeTimeout = Duration(seconds: 3);

  /// Interface events arrive in bursts during a wi-fi → cellular handover, and
  /// an intermediate `none` would otherwise flash the banner mid-switch.
  static const Duration _settle = Duration(milliseconds: 900);

  /// A probe is worth caching for a moment so rapid rebuilds do not each fire a
  /// request, but not long enough to keep asserting a state that has changed.
  static const Duration _cacheFor = Duration(seconds: 10);

  http.Client _client = http.Client();
  bool? _lastProbe;
  DateTime? _lastProbeAt;

  /// Swap the client and clear cached state. Tests only.
  void debugSetClient(http.Client client) {
    _client = client;
    _lastProbe = null;
    _lastProbeAt = null;
  }

  /// True when the device cannot reach the internet.
  Future<bool> get isCurrentlyOffline async {
    try {
      final results = await Connectivity().checkConnectivity();
      // `await`, not a bare return: returning the future would hand it back
      // before this try block closes, so a failure inside offlineFor — the
      // probe timing out, say — would escape the catch below entirely.
      return await offlineFor(results);
    } catch (_) {
      // Neither a platform channel failure nor a failed probe is evidence of
      // being offline, and claiming so would show a banner over a working app.
      return false;
    }
  }

  /// Offline state over time, debounced and de-duplicated.
  Stream<bool> get isOfflineStream => Connectivity()
      .onConnectivityChanged
      .debounce(_settle)
      .asyncMap(offlineFor)
      .distinct();

  /// Offline verdict for a set of interface states.
  ///
  /// Public so it can be exercised without a platform channel — the
  /// `checkConnectivity()` call above is unavailable under `flutter test`, and
  /// wrapping it in try/catch means an untestable path would silently swallow
  /// the very logic worth testing.
  @visibleForTesting
  Future<bool> offlineFor(List<ConnectivityResult> results) async {
    if (_hasNoInterface(results)) {
      // Conclusive: nothing to probe over. Drop the cache so reconnecting
      // re-probes immediately instead of trusting a stale result.
      _lastProbe = null;
      _lastProbeAt = null;
      return true;
    }
    return !await _canReachInternet();
  }

  /// An empty list is NOT "no interface".
  ///
  /// `Iterable.every` is vacuously true for an empty list, so the obvious
  /// `results.every((r) => r == none)` reports *offline* when the platform
  /// returns nothing at all — a false banner over a working app.
  bool _hasNoInterface(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return results.every((r) => r == ConnectivityResult.none);
  }

  Future<bool> _canReachInternet() async {
    final at = _lastProbeAt;
    final cached = _lastProbe;
    if (cached != null && at != null && DateTime.now().difference(at) < _cacheFor) {
      return cached;
    }

    bool reachable;
    try {
      final res = await _client.get(_probeUrl).timeout(_probeTimeout);
      reachable = res.statusCode == 204 || res.statusCode == 200 && res.body.isEmpty;
    } catch (_) {
      // Timeout, DNS failure, TLS failure, no route — all mean unreachable.
      reachable = false;
    }

    _lastProbe = reachable;
    _lastProbeAt = DateTime.now();
    return reachable;
  }
}

extension _Debounce<T> on Stream<T> {
  /// Emit only after [duration] passes without another event.
  Stream<T> debounce(Duration duration) {
    Timer? timer;
    return transform(
      StreamTransformer<T, T>.fromHandlers(
        handleData: (value, sink) {
          timer?.cancel();
          timer = Timer(duration, () => sink.add(value));
        },
        handleDone: (sink) {
          timer?.cancel();
          sink.close();
        },
      ),
    );
  }
}
