// lib/features/settings/pages/notifications_settings_page.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/auth/services/user_settings_service.dart';
import '../../../core/services/fcm_service.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/models/user_settings.dart';
import '../widgets/notification_frequency_picker.dart';

class NotificationsSettingsPage extends StatefulWidget {
  const NotificationsSettingsPage({super.key});

  @override
  State<NotificationsSettingsPage> createState() =>
      _NotificationsSettingsPageState();
}

class _NotificationsSettingsPageState extends State<NotificationsSettingsPage> {
  final UserSettingsService _userSettingsService = UserSettingsService();
  final FCMService _fcmService = FCMService();

  bool _notificationsEnabled = false;
  int _notificationFrequency = 1;
  bool _isLoading = true;
  bool _isUpdating = false;
  UserSettings? _userSettings;

  @override
  void initState() {
    super.initState();
    _loadUserSettings();
  }

  Future<void> _loadUserSettings() async {
    try {
      final authProvider = context.read<AuthProvider>();
      final userId = authProvider.currentUser?.uid;

      if (userId == null) {
        AppLogger.warning('NotificationSettings', 'No user logged in');
        return;
      }

      final settings = await _userSettingsService.getUserSettings(userId);
      if (settings != null && mounted) {
        setState(() {
          _userSettings = settings;
          _notificationsEnabled = settings.enableNotifications;
          _notificationFrequency = settings.notificationFrequency;
          _isLoading = false;
        });
      }
    } catch (e) {
      AppLogger.error('NotificationSettings', 'Error loading settings', e);
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _toggleNotifications(bool value) async {
    if (_isUpdating) return;

    setState(() {
      _isUpdating = true;
    });

    try {
      final authProvider = context.read<AuthProvider>();
      final userId = authProvider.currentUser?.uid;

      if (userId == null) {
        _showError('Please log in to change notification settings');
        return;
      }

      if (value) {
        // Enabling notifications - get FCM token
        AppLogger.info('NotificationSettings', 'Enabling notifications');
        final success = await _fcmService.enableNotifications(userId);

        if (!success) {
          _showError(
            'Failed to enable notifications. Please check your device settings.',
          );
          return;
        }
      } else {
        // Disabling notifications - clear FCM token
        AppLogger.info('NotificationSettings', 'Disabling notifications');
        await _fcmService.disableNotifications(userId);
      }

      // Update user settings
      final updatedSettings = await _userSettingsService.updateNotifications(
        userId,
        value,
      );

      if (updatedSettings != null && mounted) {
        setState(() {
          _userSettings = updatedSettings;
          _notificationsEnabled = value;
        });

        _showSuccess(
          value ? 'Notifications enabled' : 'Notifications disabled',
        );
      } else {
        _showError('Failed to update notification settings');
      }
    } catch (e) {
      AppLogger.error('NotificationSettings', 'Error toggling notifications', e);
      _showError('Error updating notifications: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  Future<void> _updateFrequency(int frequency) async {
    if (_isUpdating) return;

    setState(() {
      _isUpdating = true;
    });

    try {
      final authProvider = context.read<AuthProvider>();
      final userId = authProvider.currentUser?.uid;

      if (userId == null) {
        _showError('Please log in to change settings');
        return;
      }

      final updatedSettings = await _userSettingsService
          .updateNotificationFrequency(userId, frequency);

      if (updatedSettings != null && mounted) {
        setState(() {
          _userSettings = updatedSettings;
          _notificationFrequency = frequency;
        });

        _showSuccess('Check frequency updated');
      } else {
        _showError('Failed to update frequency');
      }
    } catch (e) {
      AppLogger.error('NotificationSettings', 'Error updating frequency', e);
      _showError('Error updating frequency: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;

    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;

    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Success'),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Notifications'),
      ),
      child: SafeArea(
        child: _isLoading
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Main notification toggle
                  _buildNotificationToggle(),

                  const SizedBox(height: 16),

                  // Frequency picker (only show when notifications enabled)
                  if (_notificationsEnabled) ...[
                    NotificationFrequencyPicker(
                      selectedFrequency: _notificationFrequency,
                      onChanged: _updateFrequency,
                      isEnabled: !_isUpdating,
                    ),
                    const SizedBox(height: 16),
                  ],

                  const SizedBox(height: 24),

                  // Status section
                  _buildStatusSection(),
                ],
              ),
      ),
    );
  }

  Widget _buildNotificationToggle() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.systemGrey.resolveFrom(context),
        ),
      ),
      child: Row(
        children: [
          Icon(
            _notificationsEnabled
                ? CupertinoIcons.bell_fill
                : CupertinoIcons.bell_slash,
            color: _notificationsEnabled
                ? CupertinoColors.systemBlue.resolveFrom(context)
                : CupertinoColors.systemGrey.resolveFrom(context),
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'River Flood Alerts',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Get notified when your favorite rivers exceed flood thresholds',
                  style: TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (_isUpdating)
            const CupertinoActivityIndicator()
          else
            CupertinoSwitch(
              value: _notificationsEnabled,
              onChanged: _toggleNotifications,
            ),
        ],
      ),
    );
  }

  Widget _buildStatusSection() {
    if (_userSettings == null) return const SizedBox.shrink();

    final hasToken = _userSettings!.hasValidFCMToken;
    final favoriteCount = _userSettings!.favoriteReachIds.length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemBackground.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Status',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 12),

          // Notification status
          Row(
            children: [
              Icon(
                hasToken
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.xmark_circle_fill,
                color: hasToken
                    ? CupertinoColors.systemGreen.resolveFrom(context)
                    : CupertinoColors.systemRed.resolveFrom(context),
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                hasToken
                    ? 'Device registered for notifications'
                    : 'Device not registered',
                style: TextStyle(
                  fontSize: 14,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Favorites count
          Row(
            children: [
              Icon(
                favoriteCount > 0
                    ? CupertinoIcons.heart_fill
                    : CupertinoIcons.heart,
                color: favoriteCount > 0
                    ? CupertinoColors.systemRed.resolveFrom(context)
                    : CupertinoColors.systemGrey.resolveFrom(context),
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                favoriteCount > 0
                    ? '$favoriteCount favorite rivers being monitored'
                    : 'No favorite rivers to monitor',
                style: TextStyle(
                  fontSize: 14,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),

          if (favoriteCount == 0) ...[
            const SizedBox(height: 8),
            Text(
              'Add rivers to your favorites to receive flood alerts',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
