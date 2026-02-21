// lib/features/settings/widgets/notification_frequency_picker.dart

import 'package:flutter/cupertino.dart';

/// Widget for selecting notification frequency (1x, 2x, 3x, or 4x per day)
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
        'CHECK FREQUENCY',
        style: TextStyle(
          fontSize: 13,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
      // footer: Text(
      //   'Choose how often we check your favorite rivers for flood alerts',
      //   style: TextStyle(
      //     fontSize: 13,
      //     color: CupertinoColors.secondaryLabel.resolveFrom(context),
      //   ),
      // ),
      children: [
        _buildFrequencyTile(
          context,
          frequency: 1,
          title: 'Once daily',
          subtitle: '6:00 AM MT',
        ),
        _buildFrequencyTile(
          context,
          frequency: 2,
          title: 'Twice daily',
          subtitle: '6:00 AM, 6:00 PM MT',
        ),
        _buildFrequencyTile(
          context,
          frequency: 3,
          title: 'Three times daily',
          subtitle: '6:00 AM, 12:00 PM, 6:00 PM MT',
        ),
        _buildFrequencyTile(
          context,
          frequency: 4,
          title: 'Four times daily',
          subtitle: '12:00 AM, 6:00 AM, 12:00 PM, 6:00 PM MT',
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
            )
          : null,
      onTap: isEnabled ? () => onChanged(frequency) : null,
    );
  }
}
