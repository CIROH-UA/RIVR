// lib/ui/2_presentation/features/forecast/widgets/reach_alert_frequency_row.dart
//
// "Alerts: Every 6 hours ›" on a river's own forecast page.
//
// **This exists because of where the annoyance happens.** A flood notification
// deep-links to this page (`notification-service.ts` sets `type`, `reachId` and
// `source` on the payload, and the tap handler routes here). Until now the only
// way to change how often that river notified you was: favourites page → a
// custom overflow menu → Notifications → scroll past two sections. UI review
// called it out — the person actually woken at 3am had no route to the fix from
// where they were standing.
//
// So the control lives at the end of the notification's own journey. Tap the
// alert, land on the river, change the setting.
//
// Only shown for a FAVOURITED river: the per-river setting is stored against a
// favourite, and offering it on a river nobody follows would promise a
// preference with nowhere to live.

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';

import 'package:rivr/models/1_domain/shared/alert_frequency.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/settings/widgets/river_alert_frequency_section.dart';

/// A single row showing, and letting the user change, how often this river
/// reminds them while it stays flooded.
///
/// **Renders nothing rather than throwing when its dependencies are absent.**
/// This is an enhancement on a page whose job is the forecast, and the forecast
/// page is reachable from a deep link, the map and a notification tap — provider
/// trees that are not identical. Requiring `AuthProvider` unconditionally made
/// the page itself un-renderable without it, which its own widget tests caught
/// immediately; in production it would have been a crash on some route rather
/// than a missing row.
class ReachAlertFrequencyRow extends StatefulWidget {
  const ReachAlertFrequencyRow({
    super.key,
    required this.reachId,
    required this.riverName,
  });

  final String reachId;
  final String riverName;

  @override
  State<ReachAlertFrequencyRow> createState() => _ReachAlertFrequencyRowState();
}

class _ReachAlertFrequencyRowState extends State<ReachAlertFrequencyRow> {
  UserSettings? _settings;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The signed-in user, or null when no [AuthProvider] is above this widget.
  ///
  /// `context.read` THROWS when the provider is missing; this widget must
  /// degrade instead. See the class doc.
  AuthProvider? get _auth {
    try {
      return context.read<AuthProvider>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _load() async {
    final userId = _auth?.currentUser?.uid;
    if (userId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final settings =
          await GetIt.I<IUserSettingsService>().getUserSettings(userId);
      if (mounted) {
        setState(() {
          _settings = settings;
          _loading = false;
        });
      }
    } catch (e) {
      // A settings read failure hides the row rather than showing a broken
      // one. The forecast itself is the reason the user is here.
      AppLogger.error('ReachAlertFrequencyRow', 'Error loading settings: $e', e);
      if (mounted) setState(() => _loading = false);
    }
  }

  AlertFrequency get _current {
    final settings = _settings;
    if (settings == null) return AlertFrequency.defaultFrequency;
    final stored = settings.alertFrequencies[widget.reachId];
    return stored != null
        ? AlertFrequency.fromWire(stored)
        : AlertFrequency.defaultFor(settings.notificationFrequency);
  }

  bool get _isDefault =>
      _settings?.alertFrequencies.containsKey(widget.reachId) != true;

  Future<void> _save(AlertFrequency frequency) async {
    final userId = _auth?.currentUser?.uid;
    final settings = _settings;
    if (userId == null || settings == null) return;

    final previous = settings;
    setState(() {
      _settings = settings.copyWith(
        alertFrequencies: {
          ...settings.alertFrequencies,
          widget.reachId: frequency.wireValue,
        },
      );
    });

    try {
      final saved = await GetIt.I<IUserSettingsService>()
          .updateRiverAlertFrequency(
        userId,
        widget.reachId,
        frequency.wireValue,
      );
      if (saved == null) throw Exception('settings unavailable');
    } catch (e) {
      AppLogger.error('ReachAlertFrequencyRow', 'Error saving: $e', e);
      if (mounted) setState(() => _settings = previous);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();

    // Favourites only — see the note at the top of this file. Same defensive
    // lookup as _auth, for the same reason.
    final bool isFavorite;
    try {
      isFavorite = context.select<FavoritesProvider, bool>(
        (p) => p.favorites.any((f) => f.reachId == widget.reachId),
      );
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    if (!isFavorite) return const SizedBox.shrink();

    // Notifications off account-wide: a per-river reminder setting would be
    // inert, and offering it would imply alerts are coming.
    if (_settings?.enableNotifications != true) return const SizedBox.shrink();

    final current = _current;
    final muted = current == AlertFrequency.off;
    final grey = CupertinoColors.secondaryLabel.resolveFrom(context);

    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.fromLTRB(18, 20, 18, 0),
      // TRANSPARENT, not the default.
      //
      // `insetGrouped` paints `systemGroupedBackground` — a light grey — as a
      // full-width band behind and below its card. That is right on a settings
      // page, which is grey all over. This page is not: its scaffold draws a
      // gradient ending in pure white, so the band read as a strip of a
      // slightly different shade across the bottom of the forecast. Reported
      // on device, and mistaken for a safe-area artefact, which is what it
      // looks like.
      backgroundColor: const Color(0x00000000),
      children: [
        CupertinoListTile(
          leading: Icon(
            muted ? CupertinoIcons.bell_slash : CupertinoIcons.bell,
            size: 20,
            color: muted ? grey : CupertinoColors.systemBlue.resolveFrom(context),
          ),
          title: const Text('Alerts'),
          subtitle: muted
              ? Text('Still alerts if it gets worse',
                  style: TextStyle(fontSize: 13, color: grey))
              : null,
          additionalInfo: Text(current.shortLabel),
          trailing: const CupertinoListTileChevron(),
          onTap: () => Navigator.of(context).push(
            CupertinoPageRoute<void>(
              builder: (_) => RiverAlertFrequencyPage(
                riverName: widget.riverName,
                selected: current,
                isDefault: _isDefault,
                previousPageTitle: 'Back',
                onChanged: _save,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
