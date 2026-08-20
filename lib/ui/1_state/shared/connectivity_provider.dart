// lib/ui/1_state/shared/connectivity_provider.dart

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:rivr/services/4_infrastructure/network/connectivity_service.dart';

class ConnectivityProvider extends ChangeNotifier {
  bool _isOffline = false;
  bool _disposed = false;
  StreamSubscription<bool>? _sub;

  bool get isOffline => _isOffline;

  ConnectivityProvider() {
    // The first check is async and the provider can be torn down before it
    // resolves — on a fast navigation away, or in a widget test that pumps and
    // ends. notifyListeners() after dispose throws, so the result is dropped
    // rather than applied.
    unawaited(
      ConnectivityService.instance.isCurrentlyOffline
          .then(_set)
          // Never rethrow: a failed connectivity check is not worth crashing
          // the app over, and the stream below will correct it.
          .catchError((_) {}),
    );

    _sub = ConnectivityService.instance.isOfflineStream.listen(
      _set,
      onError: (_) {},
    );
  }

  void _set(bool offline) {
    if (_disposed || _isOffline == offline) return;
    _isOffline = offline;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
