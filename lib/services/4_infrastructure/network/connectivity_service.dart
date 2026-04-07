// lib/services/4_infrastructure/network/connectivity_service.dart

import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityService {
  ConnectivityService._internal();
  static final ConnectivityService instance = ConnectivityService._internal();

  Stream<bool> get isOfflineStream => Connectivity()
      .onConnectivityChanged
      .map((results) => results.every((r) => r == ConnectivityResult.none));

  Future<bool> get isCurrentlyOffline async {
    final results = await Connectivity().checkConnectivity();
    return results.every((r) => r == ConnectivityResult.none);
  }
}
