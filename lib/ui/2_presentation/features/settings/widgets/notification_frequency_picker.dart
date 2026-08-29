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
        'told the moment a river floods or gets worse — this only changes how '
        'often you are reminded while it stays high.',
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
    final isSelected = selectedFrequency == frequency;

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
