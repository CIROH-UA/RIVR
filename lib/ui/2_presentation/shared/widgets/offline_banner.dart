// lib/ui/2_presentation/shared/widgets/offline_banner.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/shared/connectivity_provider.dart';

/// A bar across the top of the screen while the device cannot reach the
/// internet. It shows on the way down and simply goes away on the way back up —
/// no confirmation toast, because "the warning stopped" already says it.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  /// Dark text on the orange, not white.
  ///
  /// White on iOS systemOrange measures 2.2:1, well under the 4.5:1 WCAG AA
  /// needs for text this size; the same orange with near-black text measures
  /// 9.55:1. The colour was never the problem — the foreground was.
  static const Color _ink = Color(0xFF1A1300);

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectivityProvider>(
      builder: (context, conn, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          // Slide down from behind the nav bar and take up real height as it
          // goes, so the content below is pushed rather than covered.
          transitionBuilder: (child, animation) => SizeTransition(
            sizeFactor: animation,
            axisAlignment: -1,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: conn.isOffline
              ? const _Bar(key: ValueKey('offline'))
              : const SizedBox(width: double.infinity, key: ValueKey('online')),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // Without this the change is visual only — VoiceOver never learns the
      // app went offline.
      liveRegion: true,
      container: true,
      // The child's own Text node would otherwise compete with this label and
      // VoiceOver would read the terse visual string instead of the sentence
      // that actually explains the consequence.
      excludeSemantics: true,
      label: 'No internet connection. Data may be out of date.',
      child: Container(
        width: double.infinity,
        color: CupertinoColors.systemOrange.resolveFrom(context),
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 14),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.wifi_slash,
                size: 14, color: OfflineBanner._ink),
            SizedBox(width: 7),
            Flexible(
              child: Text(
                'No internet connection',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: OfflineBanner._ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
