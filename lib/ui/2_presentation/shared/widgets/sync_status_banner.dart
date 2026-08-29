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
// systemOrange (white measured 2.2:1 against WCAG AA's 4.5:1; this measures
// 9.55:1), the Semantics wrapper, and an AnimatedSwitcher that shows on the
// way down and simply disappears on the way back up.
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
// **The second cause shares the server's threshold, which is guard 4.**
// `IRiverDataRepository.outOfSync` rises only when a value was served past its
// window and revalidation failed. A document's window comes from the same
// per-product `MAX_HOLD_MS` that `assessProductFreshness`
// (functions/src/store-trigger.ts) alarms on — the store's answer to "how long
// can upstream be quiet before silence means broken". Guard 4 asks that the
// user-facing indicator be driven by the same signal that alarms
// operationally; sharing the threshold instead of picking a second number is
// what makes that true and keeps it true as the number changes.

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

/// The app's single freshness indicator. Renders nothing at all when the app
/// can vouch for its data — which is almost always, and is the point.
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
