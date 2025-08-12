// lib/features/settings/pages/notifications_settings_page.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/auth/services/user_settings_service.dart';
import '../../../core/services/fcm_service.dart';
import '../../../core/models/user_settings.dart';

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
        print('NOTIFICATIONS_SETTINGS: No user logged in');
        return;
      }

      final settings = await _userSettingsService.getUserSettings(userId);
      if (settings != null && mounted) {
        setState(() {
          _userSettings = settings;
          _notificationsEnabled = settings.enableNotifications;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('NOTIFICATIONS_SETTINGS: Error loading settings: $e');
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
        print('NOTIFICATIONS_SETTINGS: Enabling notifications');
        final success = await _fcmService.enableNotifications(userId);

        if (!success) {
          _showError(
            'Failed to enable notifications. Please check your device settings.',
          );
          return;
        }
      } else {
        // Disabling notifications - clear FCM token
        print('NOTIFICATIONS_SETTINGS: Disabling notifications');
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
      print('NOTIFICATIONS_SETTINGS: Error toggling notifications: $e');
      _showError('Error updating notifications: ${e.toString()}');
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

    // Simple success feedback - you could replace with a more subtle indicator
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

                  // Explanation text
                  _buildExplanationSection(),

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

  Widget _buildExplanationSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemBackground.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.info_circle,
                color: CupertinoColors.systemBlue.resolveFrom(context),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'How it works',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '• Notifications are sent only for rivers in your favorites list\n'
            '• Alerts trigger when forecasts exceed flood return periods (2-year, 5-year, etc.)\n'
            '• You\'ll receive notifications in your preferred flow units (CFS or CMS)\n'
            '• Alerts are checked every 6 hours to avoid spam',
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
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
