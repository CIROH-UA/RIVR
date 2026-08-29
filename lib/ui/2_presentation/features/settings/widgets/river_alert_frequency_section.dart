// lib/ui/2_presentation/features/settings/widgets/river_alert_frequency_section.dart
//
// Per-river reminder frequency (ADR 0011 decision 19).
//
// **Why it lives in Notification settings and not on the favourite card.** The
// card already carries three slide actions — delete, rename, image — and
// `SlideActionConstants` sizes the reveal from exactly three. A fourth would
// crowd a gesture people use to delete things. This is also simply where a
// person looks when they think "this river is notifying me too much", and a
// list scales to twenty favourites where a per-card gesture does not.
//
// **The honesty problem this UI has to solve.** "Off" does not mean silent: an
// escalation still comes through, because a river going from Action to Extreme
// at 3am must wake someone regardless of what they chose. A settings row that
// says "Off" and then notifies reads as a bug, so the section states the rule
// where it cannot be missed rather than burying it.

import 'package:flutter/cupertino.dart';

import 'package:rivr/models/1_domain/shared/alert_frequency.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';

/// A settings section listing each favourite river and its reminder frequency.
class RiverAlertFrequencySection extends StatelessWidget {
  const RiverAlertFrequencySection({
    super.key,
    required this.favorites,
    required this.frequencies,
    required this.onChanged,
    this.isEnabled = true,
  });

  /// The user's favourite rivers, in their chosen order.
  final List<FavoriteRiver> favorites;

  /// Stored wire values keyed by reach id. Missing means the default.
  final Map<String, String> frequencies;

  /// Called with the reach id and the newly chosen frequency.
  final void Function(String reachId, AlertFrequency frequency) onChanged;

  final bool isEnabled;

  @override
  Widget build(BuildContext context) {
    if (favorites.isEmpty) {
      return CupertinoListSection.insetGrouped(
        header: const Text('EACH RIVER'),
        footer: const Text(
          'Rivers you favorite will appear here, so you can set how often each '
          'one reminds you.',
        ),
        children: const [
          CupertinoListTile(
            title: Text('No favorite rivers yet'),
          ),
        ],
      );
    }

    return CupertinoListSection.insetGrouped(
      header: const Text('EACH RIVER'),
      // The rule that makes "Off" honest. Stated once, here, where someone
      // choosing "Off" will read it.
      footer: const Text(
        'You are always told the moment a river floods or gets worse. These '
        'settings only change how often you are reminded while it stays high — '
        'and a river set to Off will still alert you if it gets worse.',
      ),
      children: [
        for (final favorite in favorites)
          _RiverRow(
            favorite: favorite,
            frequency: AlertFrequency.fromWire(frequencies[favorite.reachId]),
            isEnabled: isEnabled,
            onChanged: (f) => onChanged(favorite.reachId, f),
          ),
      ],
    );
  }
}

class _RiverRow extends StatelessWidget {
  const _RiverRow({
    required this.favorite,
    required this.frequency,
    required this.isEnabled,
    required this.onChanged,
  });

  final FavoriteRiver favorite;
  final AlertFrequency frequency;
  final bool isEnabled;
  final ValueChanged<AlertFrequency> onChanged;

  /// `FavoriteRiver.displayName` already encodes the priority — custom name,
  /// then river name, then a source-appropriate fallback. Reimplementing it
  /// here would make a fourth naming rule for one river.
  String get _name => favorite.displayName;

  @override
  Widget build(BuildContext context) {
    final muted = frequency == AlertFrequency.off;

    return CupertinoListTile(
      title: Text(_name, overflow: TextOverflow.ellipsis),
      // The current setting is visible without tapping in, so a user scanning
      // for "which one is shouting at me" does not have to open five sheets.
      additionalInfo: Text(
        frequency.shortLabel,
        style: TextStyle(
          color: muted
              ? CupertinoColors.secondaryLabel.resolveFrom(context)
              : CupertinoColors.label.resolveFrom(context),
        ),
      ),
      leading: Icon(
        muted ? CupertinoIcons.bell_slash : CupertinoIcons.bell,
        size: 20,
        color: muted
            ? CupertinoColors.secondaryLabel.resolveFrom(context)
            : CupertinoColors.systemBlue.resolveFrom(context),
      ),
      trailing: const CupertinoListTileChevron(),
      onTap: isEnabled ? () => _present(context) : null,
    );
  }

  void _present(BuildContext context) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(_name),
        message: const Text(
          'How often should we remind you while this river stays high?',
        ),
        actions: [
          for (final option in AlertFrequency.values)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(sheetContext);
                if (option != frequency) onChanged(option);
              },
              isDefaultAction: option == frequency,
              // "Off" is destructive-coloured because it is the one choice
              // that removes information the user would otherwise get.
              isDestructiveAction: option == AlertFrequency.off,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.label,
                    style: TextStyle(
                      fontWeight: option == frequency
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    option.description,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel
                          .resolveFrom(sheetContext),
                    ),
                  ),
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('Cancel'),
        ),
      ),
    );
  }
}
