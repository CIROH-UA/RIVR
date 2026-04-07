// lib/ui/2_presentation/shared/widgets/offline_banner.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/shared/connectivity_provider.dart';

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectivityProvider>(
      builder: (context, conn, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: conn.isOffline
              ? Container(
                  key: const ValueKey('offline'),
                  width: double.infinity,
                  color: CupertinoColors.systemOrange,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: const Text(
                    'No internet connection',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: CupertinoColors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('online')),
        );
      },
    );
  }
}
