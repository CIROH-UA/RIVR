// lib/ui/2_presentation/features/settings/widgets/notification_frequency_picker.dart

import 'package:flutter/cupertino.dart';

/// Default reminder frequency for rivers the user has not set individually.
///
/// **This used to be "CHECK FREQUENCY", and it advertised times that no longer
/// exist.** The rows read "6:00 AM, 12:00 PM, 6:00 PM MT" and named four
/// scheduled functions that ADR 0011 Phase 6 deleted — alerts are now evaluated
/// whenever the upstream model publishes, not on a clock. Shipping a settings
/// screen that promises a 6:00 AM check is worse than shipping no setting at
/// all, so the whole section is re-framed around the only thing a user still
/// chooses: how often to be reminded while a river stays high.
///
/// The stored value is unchanged (1-4) so no migration is needed; the server
/// reads it as this user's DEFAULT reminder interval until they set a
/// per-river preference. See `defaultFrequencyFor` in notification-service.ts.
///
/// **The footer once said "you are always told the moment a river floods".**
/// That sentence was removed from river_alert_frequency_section.dart as a lie
/// — `off` suppresses the first alert — and survived here, in the section that
/// points directly at where a user sets a river to Off. Caught by an
/// independent docs audit 2026-08-30. Only escalation is unconditional.
class NotificationFrequencyPicker extends StatelessWidget {
  final int selectedFrequency;
  final ValueChanged<int> onChanged;
  final bool isEnabled;

  const NotificationFrequencyPicker({
    super.key,
    required this.selectedFrequency,
    required this.onChanged,
    this.isEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoListSection.insetGrouped(
      header: Text(
        'DEFAULT REMINDERS',
        style: TextStyle(
          fontSize: 13,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
      footer: Text(
        'Used for rivers you have not set individually below. You are always '
        'told when a river gets worse, even one set to Off — this only changes '
        'how often you are reminded while it stays flooded.',
        style: TextStyle(
          fontSize: 13,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
      children: [
        _buildFrequencyTile(
          context,
          frequency: 1,
          title: 'Once a day',
          subtitle: 'One reminder a day while a river stays high',
        ),
        _buildFrequencyTile(
          context,
          frequency: 4,
          title: 'Every 6 hours',
          subtitle: 'The standard reminder rhythm',
        ),
      ],
    );
  }

  Widget _buildFrequencyTile(
    BuildContext context, {
    required int frequency,
    required String title,
    required String subtitle,
  }) {
    // Anything other than 1 selects "Every 6 hours".
    //
    // The old UI offered 2 and 3 as well, and both are real stored values. With
    // only two rows now, an exact match left a user on 2 or 3 looking at a
    // section with NOTHING ticked — the screen unable to say what it would do.
    // The server already treats them this way (`defaultFrequencyFor` maps
    // anything but 1 to "6h"), so this makes the screen agree with it.
    final isSelected =
        frequency == 1 ? selectedFrequency == 1 : selectedFrequency != 1;

    return CupertinoListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: isSelected
          ? const Icon(
              CupertinoIcons.checkmark,
              color: CupertinoColors.systemBlue,
              size: 20,
              semanticLabel: 'Selected',
            )
          : null,
      onTap: isEnabled ? () => onChanged(frequency) : null,
    );
  }
}
