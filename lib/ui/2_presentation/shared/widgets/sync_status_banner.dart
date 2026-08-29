// lib/ui/2_presentation/shared/widgets/sync_status_banner.dart
//
// ADR 0011 Phase 7 — the trust model, made visible.
//
// Phase 7 removes every freshness timestamp from the value surfaces. That is a
// promise, not a tidy-up: afterwards a user CANNOT tell a stale number from a
// current one, because we have trained them not to look. The ADR is blunt
// about the risk — "a silently-failing store is the most dangerous outcome in
// this document" — so the app owes exactly one thing in return.
//
// This is that one thing, and "one" is the specification: *"One unobtrusive
// indicator only when the app knows it is out of sync — offline, or the store
// has not advanced past an expected cycle. Silence means current."* Two
// separate strips would be two competing claims about the same question.
//
// **It replaces OfflineBanner** rather than stacking above it. Offline is one
// of the two reasons the app cannot vouch for a number, not a separate
// subject, and the old banner's hard-won parts are kept: the near-black ink on
// systemOrange (white measures 2.2:1 against WCAG AA's 4.5:1; #1A1300 on
// #FF9500 measures 8.40:1 — the 9.55:1 previously quoted here is the figure
// for pure black, not for the ink actually shipped), the Semantics wrapper,
// and an AnimatedSwitcher that shows on the way down and simply disappears on
// the way back up.
//
// **What raises it:**
//
// | Situation                                    | Banner            |
// |----------------------------------------------|-------------------|
// | Everything inside its window, online          | nothing           |
// | Offline                                       | "No internet"     |
// | Serving data past its window, refresh failed  | "may not be current" |
// | Online, a fetch failed, data still fresh      | nothing           |
//
// The last row is deliberate. A failure that still leaves in-window data on
// screen has cost the user nothing, and a warning there is noise that teaches
// people to ignore the strip before the day it matters.
//
// Offline wins when both are true: it is the more actionable of the two, and
// it explains the other.
//
// **Guard 4 is NOT met, and an earlier version of this comment claimed it
// was.** The claim was that a document's window comes from the same
// per-product `MAX_HOLD_MS` the server alarms on, so the indicator and the
// operational alarm are one number. That is false, and it was written without
// being checked: `MAX_HOLD_MS` exists only in TypeScript — the only occurrence
// of the name anywhere in `lib/` was the comment asserting it was shared.
//
// What actually drives each side:
//
//   this banner   `entry.window.validUntil` has passed AND the revalidation
//                 that should have replaced the value failed. For a stored
//                 document that window is `storeValidUntil` (publish
//                 alignment, ~1 h for short range); for a live-path entry it
//                 is the Dart data source's own schedule, which never touches
//                 the server at all.
//   the server    `window.fetchedAt` age against `MAX_HOLD_MS` (6 h for short
//                 range) in `assessProductFreshness`.
//
// Different functions, different magnitudes, and no shared constant. They
// correlate — both ultimately track publication — but "driven by the same
// signal" is a stronger claim than the code supports, and Phase 7 is the last
// place to overstate a guarantee. Closing this properly means the client
// learning the server's health verdict rather than inferring one; that is
// tracked as open, not quietly claimed.

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';

import 'package:rivr/services/1_contracts/shared/river_data/i_river_data_repository.dart';
import 'package:rivr/ui/1_state/shared/connectivity_provider.dart';

/// Why the app cannot currently vouch for what it is showing.
enum SyncWarning {
  /// The device cannot reach the internet.
  offline,

  /// A value was served past its window and could not be revalidated.
  stale,
}

/// The freshness indicator. Renders nothing at all when the app can vouch for
/// its data — which is almost always, and is the point.
///
/// **Mounted on the favourites page only** (`favorites_page.dart`), which is
/// where the widget it replaced was mounted. It is NOT app-wide, and the
/// header above used to say it was. The forecast page, the map's reach detail
/// sheet and the weekly outlook all render flow values through the same
/// repository and show no indicator, so a user arriving from a notification
/// deep link can read an unconfirmed number with nothing to say so. Phase 7's
/// promise is app-wide; its coverage is not, and that gap is recorded rather
/// than papered over.
class SyncStatusBanner extends StatelessWidget {
  const SyncStatusBanner({super.key, this.repository});

  /// Injectable so a widget test can drive the state directly. Falls back to
  /// the DI container, which is where every other consumer of the repository
  /// gets it (it is registered in forecast_dependencies.dart, not in the
  /// provider tree). An UNREGISTERED container degrades to offline-only rather
  /// than to a warning, because "we do not know" must never render as "we know
  /// it is stale".
  final IRiverDataRepository? repository;

  static IRiverDataRepository? _fromDi() =>
      GetIt.I.isRegistered<IRiverDataRepository>()
      ? GetIt.I<IRiverDataRepository>()
      : null;

  /// Dark text on the orange, not white. See the file header.
  static const Color ink = Color(0xFF1A1300);

  @override
  Widget build(BuildContext context) {
    final repo = repository ?? _fromDi();

    return Consumer<ConnectivityProvider>(
      builder: (context, conn, _) {
        if (repo == null) {
          return _switcher(conn.isOffline ? SyncWarning.offline : null);
        }
        return ValueListenableBuilder<bool>(
          valueListenable: repo.outOfSync,
          builder: (context, outOfSync, _) {
            // Offline wins: it is the more actionable of the two, and it
            // explains the other.
            final warning = conn.isOffline
                ? SyncWarning.offline
                : (outOfSync ? SyncWarning.stale : null);
            return _switcher(warning);
          },
        );
      },
    );
  }

  Widget _switcher(SyncWarning? warning) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: warning == null
          ? const SizedBox.shrink(key: ValueKey('sync-ok'))
          : _Bar(warning, key: ValueKey(warning)),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar(this.warning, {super.key});

  final SyncWarning warning;

  @override
  Widget build(BuildContext context) {
    final offline = warning == SyncWarning.offline;

    // Says what it means for the reader, not what failed inside the app.
    // "Revalidation failed" describes our problem; this describes theirs.
    final message = offline
        ? 'No internet connection'
        : "These numbers may not be current — we couldn't reach the latest "
              'data.';

    // Without liveRegion the change is visual only — VoiceOver never learns
    // the app went offline. `excludeSemantics` stops the inner Text being
    // announced a second time after the label.
    return Semantics(
      liveRegion: true,
      container: true,
      excludeSemantics: true,
      label: offline
          ? 'No internet connection. Data may be out of date.'
          : 'These numbers may not be current. '
                'The app could not reach the latest data.',
      child: Container(
        width: double.infinity,
        color: CupertinoColors.systemOrange.resolveFrom(context),
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              offline
                  ? CupertinoIcons.wifi_slash
                  : CupertinoIcons.exclamationmark_circle,
              size: 14,
              color: SyncStatusBanner.ink,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: SyncStatusBanner.ink,
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
