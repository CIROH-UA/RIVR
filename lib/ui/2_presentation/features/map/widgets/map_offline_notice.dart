// lib/ui/2_presentation/features/map/widgets/map_offline_notice.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/shared/connectivity_provider.dart';

/// A quiet pill telling the user why the map has stopped filling in.
///
/// Deliberately not the shared [OfflineBanner], which is a full-width solid
/// orange bar. Two reasons it cannot be reused here:
///
///  * **Orange is already taken.** On this screen orange is the Moderate rung
///    of the flood ladder, sitting in the legend a few points away. A
///    connectivity message in a flood colour would be read as a flood.
///  * A bar that spans the screen competes with the map it is describing. The
///    map is the content; this is an aside about it.
///
/// The wording matters as much as the styling. Mapbox caches tiles, so going
/// offline does not blank the map — everything already visited still draws,
/// while panning somewhere new comes up empty. "No internet connection" would
/// leave the user staring at a map that looks fine and wondering what broke;
/// naming the *new areas* explains the blankness they are about to hit.
class MapOfflineNotice extends StatelessWidget {
  const MapOfflineNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectivityProvider>(
      builder: (context, conn, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SizeTransition(
              sizeFactor: animation,
              alignment: Alignment.topCenter,
              child: child,
            ),
          ),
          child: conn.isOffline
              ? const _Pill(key: ValueKey('offline'))
              : const SizedBox.shrink(key: ValueKey('online')),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({super.key});

  @override
  Widget build(BuildContext context) {
    final label = CupertinoColors.secondaryLabel.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        // Matches the flood legend's material so the two read as one family of
        // map furniture rather than an alert pasted on top.
        color: CupertinoColors.systemBackground
            .resolveFrom(context)
            .withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.wifi_slash, size: 13, color: label),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Offline · new areas won’t load',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: label,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
