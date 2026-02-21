// lib/features/settings/pages/notifications_settings_page.dart

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import 'package:rivr/core/services/i_user_settings_service.dart';
import 'package:rivr/core/services/i_fcm_service.dart';
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
  final IUserSettingsService _userSettingsService = GetIt.I<IUserSettingsService>();
  final IFCMService _fcmService = GetIt.I<IFCMService>();

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
        // Enabling notifications - request permission and get FCM token
        AppLogger.info('NotificationSettings', 'Enabling notifications');
        final result = await _fcmService.enableNotifications(userId);

        if (result == NotificationPermissionResult.permanentlyDenied ||
            result == NotificationPermissionResult.denied) {
          _showPermissionDeniedDialog();
          return;
        }

        if (result != NotificationPermissionResult.granted) {
          _showError('Failed to enable notifications. Please try again.');
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

        // Refresh AuthProvider so favorites page banner re-evaluates
        if (mounted) {
          context.read<AuthProvider>().refreshUserSettings();
        }
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

  void _showPermissionDeniedDialog() {
    if (!mounted) return;

    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Notifications Blocked'),
        content: const Text(
          'Notification permission was previously denied. '
          'To enable flood alerts, open Settings and allow notifications for RIVR.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            child: const Text('Open Settings'),
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Notifications'),
        previousPageTitle: 'Settings',
      ),
      child: SafeArea(
        child: _isLoading
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                children: [
                  const SizedBox(height: 20),

                  // Section 1 — Flood alerts toggle
                  _buildToggleSection(),

                  // Section 2 — Frequency picker (only when enabled)
                  if (_notificationsEnabled)
                    NotificationFrequencyPicker(
                      selectedFrequency: _notificationFrequency,
                      onChanged: _updateFrequency,
                      isEnabled: !_isUpdating,
                    ),

                  // Section 3 — Monitoring (only when enabled)
                  if (_notificationsEnabled) _buildMonitoringSection(),
                ],
              ),
      ),
    );
  }

  Widget _buildToggleSection() {
    return CupertinoListSection.insetGrouped(
      header: const Text('FLOOD ALERTS'),
      footer: const Text(
        'Receive notifications when your favorite rivers exceed flood thresholds.',
      ),
      children: [
        CupertinoListTile(
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _notificationsEnabled
                  ? CupertinoColors.systemBlue
                  : CupertinoColors.systemGrey,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              CupertinoIcons.bell_fill,
              color: CupertinoColors.white,
              size: 18,
            ),
          ),
          title: const Text('River Flood Alerts'),
          trailing: _isUpdating
              ? const CupertinoActivityIndicator()
              : CupertinoSwitch(
                  value: _notificationsEnabled,
                  onChanged: _toggleNotifications,
                ),
        ),
      ],
    );
  }

  Widget _buildMonitoringSection() {
    final favoriteCount = _userSettings?.favoriteReachIds.length ?? 0;
    final hasFavorites = favoriteCount > 0;

    return CupertinoListSection.insetGrouped(
      header: const Text('MONITORING'),
      footer: !hasFavorites
          ? const Text(
              'Add rivers to your favorites to receive flood alerts.',
            )
          : null,
      children: [
        CupertinoListTile(
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: hasFavorites
                  ? CupertinoColors.systemRed
                  : CupertinoColors.systemGrey,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              CupertinoIcons.heart_fill,
              color: CupertinoColors.white,
              size: 18,
            ),
          ),
          title: Text(
            hasFavorites
                ? '$favoriteCount favorite river${favoriteCount == 1 ? '' : 's'}'
                : 'No favorite rivers',
          ),
          subtitle: Text(
            hasFavorites
                ? 'Being monitored for flood alerts'
                : 'None being monitored',
          ),
        ),
      ],
    );
  }
}
