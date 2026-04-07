// lib/ui/1_state/shared/connectivity_provider.dart

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:rivr/services/4_infrastructure/network/connectivity_service.dart';

class ConnectivityProvider extends ChangeNotifier {
  bool _isOffline = false;
  StreamSubscription<bool>? _sub;

  bool get isOffline => _isOffline;

  ConnectivityProvider() {
    ConnectivityService.instance.isCurrentlyOffline.then((offline) {
      _isOffline = offline;
      notifyListeners();
    });
    _sub = ConnectivityService.instance.isOfflineStream.listen((offline) {
      if (_isOffline != offline) {
        _isOffline = offline;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
