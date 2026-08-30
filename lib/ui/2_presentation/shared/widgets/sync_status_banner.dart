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
// | Situation                                     | Banner            |
// |-----------------------------------------------|-------------------|
// | Inside its window AND recently fetched, online | nothing           |
// | Offline                                        | "No internet"     |
// | Serving data past its window, refresh failed   | "may not be current" |
// | HELD past its product's cap, even if in-window | "may not be current" |
// | Online, a fetch failed, data still fresh       | nothing           |
//
// The last row is deliberate. A failure that still leaves in-window data on
// screen has cost the user nothing, and a warning there is noise that teaches
// people to ignore the strip before the day it matters.
//
// Offline wins when both are true: it is the more actionable of the two, and
// it explains the other.
//
// **Guard 4, and how it got there.** An early version of this comment claimed
// the client and server shared `MAX_HOLD_MS`. They did not — the constant
// existed only in TypeScript, and the only occurrence of the name anywhere in
// `lib/` was the comment asserting it was shared. A review found that; a later
// commit then made it true, and this comment went on asserting the opposite
// until a second review found THAT. Both errors were the same error: a
// statement about two files, checked against neither.
//
// What is true now: `hold_policy.dart` holds the client's copy of the caps,
// and `functions/src/hold-policy-drift.test.ts` reads it off disk and fails if
// the two sides diverge in either direction. The client applies the cap to the
// SERVER's `fetchedAt`, forwarded through `SourceFetchResult.fetchedAt`, not
// to its own read clock.
//
// Both of the server's dimensions are now shared, which is what finally
// closed the guard: `MAX_HOLD_MS` (how long ago we wrote) and
// `MAX_RUN_AGE_MS` (how old the water is), each mirrored in
// `hold_policy.dart` and pinned by the same drift test. The second was added
// last and matters most — it is the one that catches a store refreshing
// punctually while carrying yesterday's forecast, which the phone could not
// see at all before.

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
/// **Where it is mounted, and why not everywhere.** Full form on the
/// favourites page; [SyncStatusBanner.offlineOnly] on the reach forecast page.
/// The map has its own `MapOfflineNotice`. The weekly outlook page has
/// nothing.
///
/// That is a decision, not an oversight. The store exists so that a device
/// with internet shows the newest value that exists anywhere, so in practice
/// the reason a user sees an old number is that they are offline — and the
/// offline half is the half worth repeating. The forecast page got it because
/// that is where a flood notification lands: tapping an alert with no signal
/// used to show numbers with nothing anywhere saying the phone was offline.
///
/// The STALE half is deliberately NOT repeated there. `outOfSync` is a
/// property of the whole repository, not of the river on screen, so on a
/// single-river page it could warn about a different river entirely. It stays
/// on the favourites page, where every affected river is visible at once.
class SyncStatusBanner extends StatelessWidget {
  const SyncStatusBanner({super.key, this.repository}) : _offlineOnly = false;

  /// Reports only the offline case. See the class doc for why a single-river
  /// page must not carry a repository-wide staleness claim.
  const SyncStatusBanner.offlineOnly({super.key})
    : repository = null,
      _offlineOnly = true;

  final bool _offlineOnly;

  /// Injectable so a widget test can drive the state directly. Falls back to
  /// the DI container, which is where every other consumer of the repository
  /// gets it (it is registered in forecast_dependencies.dart, not in the
  /// provider tree). An UNREGISTERED container degrades to offline-only rather
  /// than to a warning, because "we do not know" must never render as "we know
  /// it is stale".
  final IRiverDataRepository? repository;

  /// Whether a [ConnectivityProvider] is reachable from [context].
  ///
  /// `listen: false` deliberately — this is only a presence check; the
  /// [Consumer] below does the subscribing.
  static bool _hasConnectivity(BuildContext context) {
    try {
      Provider.of<ConnectivityProvider>(context, listen: false);
      return true;
    } on ProviderNotFoundException {
      return false;
    }
  }

  static IRiverDataRepository? _fromDi() =>
      GetIt.I.isRegistered<IRiverDataRepository>()
      ? GetIt.I<IRiverDataRepository>()
      : null;

  /// Dark text on the orange, not white. See the file header.
  static const Color ink = Color(0xFF1A1300);

  @override
  Widget build(BuildContext context) {
    final repo = _offlineOnly ? null : (repository ?? _fromDi());

    // Degrade to silence when connectivity is not in the tree at all.
    //
    // `main.dart` provides it above `CupertinoApp`, so in production it is
    // always there. But a bare `Consumer` THROWS when it is not, and mounting
    // this on the reach forecast page turned that into 35 red tests at once —
    // a whole page taken down by the one widget on it whose entire job is to
    // be unobtrusive. A freshness indicator must never be the reason a value
    // screen fails to render, and silence is the honest reading anyway: not
    // knowing whether we are offline is not the same as knowing we are.
    if (!_hasConnectivity(context)) return const SizedBox.shrink();

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
