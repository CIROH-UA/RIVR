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
// **The honesty problem this UI has to solve.** "Off" is not silent: an
// escalation still comes through, because a river going from Action to Extreme
// at 3am must wake someone regardless of what they chose. A settings row that
// says "Off" and then notifies reads as a bug.
//
// The first version of this file got that wrong in a way worth recording: its
// footer read "You are always told the moment a river floods or gets worse",
// which was written before `off` was changed to suppress the FIRST alert too
// (alert-triggers.ts). The copy then promised something the server had stopped
// doing, on the one screen whose whole job is to be honest about it. The
// caveat now also lives on the muted row itself, because a footer under twenty
// rows is not read by the person who muted river three.
//
// **A pushed page, not an action sheet.** The row carries a chevron, and on
// iOS a chevron means "this pushes". Five options with two-line descriptions
// also overflow a small iPhone inside a sheet, which put "Off" — the option
// someone on this screen is most likely looking for — below the fold.

import 'package:flutter/cupertino.dart';

import 'package:rivr/models/1_domain/shared/alert_frequency.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';

/// A settings section listing each favourite river and its reminder frequency.
class RiverAlertFrequencySection extends StatelessWidget {
  const RiverAlertFrequencySection({
    super.key,
    required this.favorites,
    required this.frequencies,
    required this.defaultFrequency,
    required this.onChanged,
    required this.onChangedAll,
    this.isEnabled = true,
  });

  /// The user's favourite rivers, in their chosen order.
  final List<FavoriteRiver> favorites;

  /// Stored wire values keyed by reach id. A missing key means unset.
  final Map<String, String> frequencies;

  /// What an UNSET river actually gets, derived from the user's default with
  /// the same rule the server applies. Passed in rather than assumed: showing
  /// the enum's own default here told every user "Every 6 hours" while the
  /// server used "Daily" for them.
  final AlertFrequency defaultFrequency;

  /// Called with the reach id and the newly chosen frequency.
  final void Function(String reachId, AlertFrequency frequency) onChanged;

  /// Apply one frequency to every favourite at once.
  ///
  /// Review's point: someone with twenty favourites who wants "only when it
  /// changes" everywhere would otherwise open twenty pages. The per-river list
  /// is the precise tool; this is the blunt one, and both are needed.
  final void Function(AlertFrequency frequency) onChangedAll;

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
        children: [
          CupertinoListTile(
            title: Text(
              'No favorite rivers yet',
              // Secondary, or it reads as a river actually called that.
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ),
        ],
      );
    }

    return CupertinoListSection.insetGrouped(
      header: const Text('EACH RIVER'),
      footer: const Text(
        'You are told the moment a river starts flooding, and always when it '
        'gets worse — even a river set to Off. These settings only change how '
        'often you are reminded while it stays flooded.',
      ),
      children: [
        // Offered only where it earns its place. With three favourites the
        // list itself is faster than a bulk action; with twenty it is not.
        if (favorites.length >= 5)
          CupertinoListTile(
            leading: Icon(
              CupertinoIcons.slider_horizontal_3,
              size: 20,
              color: CupertinoColors.systemBlue.resolveFrom(context),
            ),
            title: const Text('Set all rivers'),
            trailing: const CupertinoListTileChevron(),
            onTap: isEnabled
                ? () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => RiverAlertFrequencyPage(
                          riverName: 'All ${favorites.length} rivers',
                          selected: defaultFrequency,
                          isDefault: false,
                          applyToAll: true,
                          onChanged: onChangedAll,
                        ),
                      ),
                    )
                : null,
          ),
        for (final favorite in favorites)
          _RiverRow(
            favorite: favorite,
            // Unset is shown as the effective default, marked as such, so a
            // deliberate choice is distinguishable from an inherited one.
            selected: frequencies.containsKey(favorite.reachId)
                ? AlertFrequency.fromWire(frequencies[favorite.reachId])
                : defaultFrequency,
            isDefault: !frequencies.containsKey(favorite.reachId),
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
    required this.selected,
    required this.isDefault,
    required this.isEnabled,
    required this.onChanged,
  });

  final FavoriteRiver favorite;
  final AlertFrequency selected;
  final bool isDefault;
  final bool isEnabled;
  final ValueChanged<AlertFrequency> onChanged;

  /// `FavoriteRiver.displayName` already encodes the priority — custom name,
  /// then river name, then a source-appropriate fallback. Reimplementing it
  /// here would make a fourth naming rule for one river.
  String get _name => favorite.displayName;

  @override
  Widget build(BuildContext context) {
    final muted = selected == AlertFrequency.off;
    final grey = CupertinoColors.secondaryLabel.resolveFrom(context);

    return CupertinoListTile(
      title: Text(_name, overflow: TextOverflow.ellipsis),
      // The caveat travels WITH the muted row. A footer below twenty rows is
      // not read by the person who muted river three, and a week later an
      // escalation alert from a river marked "Off" reads as a bug.
      subtitle: muted
          ? Text('Still alerts if it gets worse',
              style: TextStyle(fontSize: 13, color: grey))
          : null,
      // Left grey deliberately: the river's name is the subject of the row,
      // and shortLabel is scannable without competing with it.
      additionalInfo: Text(isDefault ? '${selected.shortLabel} ·' : selected.shortLabel),
      leading: Icon(
        muted ? CupertinoIcons.bell_slash : CupertinoIcons.bell,
        size: 20,
        color: muted ? grey : CupertinoColors.systemBlue.resolveFrom(context),
      ),
      trailing: const CupertinoListTileChevron(),
      onTap: isEnabled
          ? () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => RiverAlertFrequencyPage(
                    riverName: _name,
                    selected: selected,
                    isDefault: isDefault,
                    onChanged: onChanged,
                  ),
                ),
              )
          : null,
    );
  }
}

/// The reminder-frequency picker for one river, as a pushed page.
///
/// A page rather than an action sheet so the chevron on the row tells the
/// truth, so five options with descriptions cannot overflow a small phone, and
/// so the "Off still escalates" note can sit on the same screen as the Off row
/// rather than in a footer the user scrolled past.
///
/// Public because the settings list is not the only door. Someone woken by a
/// notification lands on that river's forecast page, and the fix has to be
/// reachable from there — review found the settings list was the ONLY route,
/// three taps behind a custom overflow menu, so the person actually annoyed at
/// 3am had nowhere to go.
class RiverAlertFrequencyPage extends StatefulWidget {
  const RiverAlertFrequencyPage({
    super.key,
    required this.riverName,
    required this.selected,
    required this.isDefault,
    required this.onChanged,
    this.previousPageTitle = 'Notifications',
    this.applyToAll = false,
  });

  /// Whether this choice will be written to EVERY favourite. Changes the
  /// wording so a bulk action cannot be mistaken for a single one.
  final bool applyToAll;

  final String previousPageTitle;
  final String riverName;
  final AlertFrequency selected;
  final bool isDefault;
  final ValueChanged<AlertFrequency> onChanged;

  @override
  State<RiverAlertFrequencyPage> createState() =>
      _RiverAlertFrequencyPageState();
}

class _RiverAlertFrequencyPageState extends State<RiverAlertFrequencyPage> {
  late AlertFrequency _selected = widget.selected;

  /// Quietest first.
  ///
  /// Anyone who reaches this screen arrived because a river is too loud, so
  /// the option they want should be the one they see first. Enum-declaration
  /// order put "Every hour" at the top and "Off" at the bottom.
  static const List<AlertFrequency> _order = [
    AlertFrequency.off,
    AlertFrequency.changeOnly,
    AlertFrequency.daily,
    AlertFrequency.sixHourly,
    AlertFrequency.hourly,
  ];

  @override
  Widget build(BuildContext context) {
    final grey = CupertinoColors.secondaryLabel.resolveFrom(context);

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.riverName, overflow: TextOverflow.ellipsis),
        previousPageTitle: widget.previousPageTitle,
      ),
      child: SafeArea(
        child: ListView(
          children: [
            const SizedBox(height: 20),
            CupertinoListSection.insetGrouped(
              header: const Text('REMIND ME'),
              footer: Text(
                widget.applyToAll
                    ? 'This replaces the setting on every river, including any '
                        'you have already set individually.\n\nYou are told '
                        'the moment a river starts flooding, and always when '
                        'it gets worse — even a river set to Off.'
                    : widget.isDefault
                        ? 'This river is using your default. Choosing here '
                            'sets it for this river only.\n\nYou are told the '
                            'moment it starts flooding, and always when it '
                            'gets worse — even if you choose Off.'
                        : 'You are told the moment it starts flooding, and '
                            'always when it gets worse — even if you choose '
                            'Off.',
              ),
              children: [
                for (final option in _order)
                  CupertinoListTile(
                    title: Text(option.label),
                    subtitle: Text(
                      option.description,
                      style: TextStyle(fontSize: 13, color: grey),
                    ),
                    trailing: option == _selected
                        ? Icon(
                            CupertinoIcons.check_mark,
                            color:
                                CupertinoColors.activeBlue.resolveFrom(context),
                          )
                        : null,
                    onTap: () {
                      if (option != _selected) {
                        setState(() => _selected = option);
                        widget.onChanged(option);
                      }
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
