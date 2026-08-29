// lib/ui/2_presentation/features/settings/pages/notifications_settings_page.dart

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';
import 'package:rivr/ui/2_presentation/features/settings/widgets/notification_frequency_picker.dart';
import 'package:rivr/ui/2_presentation/features/settings/widgets/river_alert_frequency_section.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/models/1_domain/shared/alert_frequency.dart';

class NotificationsSettingsPage extends StatefulWidget {
  const NotificationsSettingsPage({super.key});

  @override
  State<NotificationsSettingsPage> createState() =>
      _NotificationsSettingsPageState();
}

class _NotificationsSettingsPageState extends State<NotificationsSettingsPage>
    with WidgetsBindingObserver {
  final IUserSettingsService _userSettingsService = GetIt.I<IUserSettingsService>();
  final IFCMService _fcmService = GetIt.I<IFCMService>();

  bool _notificationsEnabled = false;
  int _notificationFrequency = 1;
  Map<String, String> _alertFrequencies = const {};
  bool _weeklyOutlookEnabled = false;
  bool _isLoading = true;
  bool _isUpdating = false;
  UserSettings? _userSettings;

  /// The OS permission on THIS device. A stored preference is not permission:
  /// settings sync through Firestore, so a second device can render both
  /// toggles ON having never been asked. Read on every load so the UI reports
  /// what the device can actually do, not what the account prefers.
  NotificationPermissionResult? _osPermission;

  bool get _osBlocked =>
      _osPermission == NotificationPermissionResult.permanentlyDenied ||
      _osPermission == NotificationPermissionResult.notDetermined;

  /// The OS has refused. Distinct from "not asked yet": nothing can be
  /// delivered to this device until the user changes it in system settings,
  /// and no in-app prompt can reach them.
  bool get _osDenied =>
      _osPermission == NotificationPermissionResult.permanentlyDenied;

  /// True when the user wants at least one notification type — drives whether
  /// the device-status and monitoring sections are shown.
  bool get _anyEnabled => _notificationsEnabled || _weeklyOutlookEnabled;

  @override
  void initState() {
    super.initState();
    // The only route out of a denied state is system settings, which happens
    // outside the app. Watching resume is how we notice the user came back
    // having said yes — otherwise the page keeps showing "blocked" until it is
    // reopened (ADR 0009, phase 3).
    WidgetsBinding.instance.addObserver(this);
    _loadUserSettings().then((_) => _reconcileDevice());
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
          _alertFrequencies = settings.alertFrequencies;
          _weeklyOutlookEnabled = settings.weeklyOutlookEnabled;
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

        // Ensure tap-to-navigate listeners are active immediately
        _fcmService.setupNotificationListeners();
      } else {
        // Disabling notifications - clear FCM token
        AppLogger.info('NotificationSettings', 'Disabling notifications');
        await _fcmService.disableNotifications(userId);
      }

      // Refresh local state from Firestore (enable/disable already wrote the flag)
      await _refreshOsPermission();

      final refreshedSettings =
          await _userSettingsService.getUserSettings(userId);

      if (refreshedSettings != null && mounted) {
        setState(() {
          _userSettings = refreshedSettings;
          _notificationsEnabled = refreshedSettings.enableNotifications;
          _weeklyOutlookEnabled = refreshedSettings.weeklyOutlookEnabled;
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

  /// Toggle the Weekly Outlook digest — independent from flood alerts. Shares
  /// the permission/token flow, so enabling it will prompt for permission if
  /// this is the first notification type the user turns on.
  Future<void> _toggleWeeklyOutlook(bool value) async {
    if (_isUpdating) return;
    setState(() => _isUpdating = true);

    try {
      final userId = context.read<AuthProvider>().currentUser?.uid;
      if (userId == null) {
        _showError('Please log in to change notification settings');
        return;
      }

      if (value) {
        final result = await _fcmService.enableWeeklyOutlook(userId);
        if (result == NotificationPermissionResult.permanentlyDenied ||
            result == NotificationPermissionResult.denied) {
          _showPermissionDeniedDialog();
          return;
        }
        if (result != NotificationPermissionResult.granted) {
          _showError('Failed to enable the weekly outlook. Please try again.');
          return;
        }
        _fcmService.setupNotificationListeners();
      } else {
        await _fcmService.disableWeeklyOutlook(userId);
      }

      final refreshed = await _userSettingsService.getUserSettings(userId);
      if (refreshed != null && mounted) {
        setState(() {
          _userSettings = refreshed;
          _notificationsEnabled = refreshed.enableNotifications;
          _weeklyOutlookEnabled = refreshed.weeklyOutlookEnabled;
        });
        if (mounted) context.read<AuthProvider>().refreshUserSettings();
      } else {
        _showError('Failed to update notification settings');
      }
    } catch (e) {
      AppLogger.error('NotificationSettings', 'Error toggling weekly outlook', e);
      _showError('Error updating weekly outlook: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  /// Persist one river's reminder frequency.
  ///
  /// Optimistic: the row updates immediately and reverts if the write fails.
  /// A settings toggle that waits on a round trip before moving feels broken,
  /// and this one is safe to revert because nothing else depends on it.
  Future<void> _updateRiverFrequency(
    String reachId,
    AlertFrequency frequency,
  ) async {
    final userId = context.read<AuthProvider>().currentUser?.uid;
    if (userId == null) return;

    final previous = Map<String, String>.from(_alertFrequencies);
    setState(() {
      _alertFrequencies = {
        ..._alertFrequencies,
        reachId: frequency.wireValue,
      };
    });

    try {
      await GetIt.I<IUserSettingsService>().updateRiverAlertFrequency(
        userId,
        reachId,
        frequency.wireValue,
      );
    } catch (e) {
      AppLogger.error(
        'NotificationsSettingsPage',
        'Error updating river alert frequency: $e',
        e,
      );
      if (mounted) {
        setState(() => _alertFrequencies = previous);
        _showError('Could not save that setting. Please try again.');
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
          'To receive notifications, open Settings and allow notifications for RIVR.',
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

                  // ALERTS — flood threshold pushes
                  _buildToggleSection(),
                  if (_notificationsEnabled) ...[
                    NotificationFrequencyPicker(
                      selectedFrequency: _notificationFrequency,
                      onChanged: _updateFrequency,
                      isEnabled: !_isUpdating,
                    ),
                    // Per-river overrides. Placed directly under the default
                    // so the relationship reads top-down: this is the default,
                    // these are the exceptions.
                    Consumer<FavoritesProvider>(
                      builder: (context, favorites, _) =>
                          RiverAlertFrequencySection(
                        favorites: favorites.favorites,
                        frequencies: _alertFrequencies,
                        onChanged: _updateRiverFrequency,
                        isEnabled: !_isUpdating,
                      ),
                    ),
                  ],

                  // DIGEST — weekly outlook (independent toggle)
                  _buildDigestSection(),

                  // Shared context — shown when either type is on.
                  // The OS check comes first: a registered token means nothing
                  // if this device is not allowed to post notifications.
                  if (_anyEnabled && _osBlocked) _buildOsBlockedSection(),
                  if (_anyEnabled && !_osBlocked)
                    _buildRegistrationStatusSection(),
                  if (_anyEnabled) _buildMonitoringSection(),
                ],
              ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _onReturnedFromSystemSettings();
  }

  /// Re-read the OS permission on resume and, if it has just been granted,
  /// register this device without making the user tap anything else. They have
  /// already expressed the intent twice — once via the preference, once in
  /// system settings.
  Future<void> _onReturnedFromSystemSettings() async {
    final before = _osPermission;
    await _refreshOsPermission();
    if (!mounted) return;
    final now = _osPermission;
    final justGranted = before != NotificationPermissionResult.granted &&
        now == NotificationPermissionResult.granted;
    if (!justGranted) return;

    final userId = context.read<AuthProvider>().currentUser?.uid;
    if (userId == null || !_anyEnabled) return;
    await _fcmService.reconcileDevice(userId, wantsAny: true);
    if (mounted) await _loadUserSettings();
  }

  Future<void> _refreshOsPermission() async {
    final p = await _fcmService.osPermissionStatus();
    if (mounted) setState(() => _osPermission = p);
  }

  /// Ask this device for permission if the account already wants notifications
  /// but the OS has never been asked (ADR 0009, phase 1).
  ///
  /// Runs when this page opens rather than at launch: the user is looking at
  /// notification settings, so a permission prompt is the least surprising
  /// thing that could happen. The service asks at most once per session and
  /// never when denied, so calling this on every open is safe.
  Future<void> _reconcileDevice() async {
    final userId = context.read<AuthProvider>().currentUser?.uid;
    if (userId == null) return;
    if (!_anyEnabled) return;
    await _fcmService.reconcileDevice(userId, wantsAny: true);
    await _refreshOsPermission();
  }

  /// Shown when the account wants notifications but this device cannot post
  /// them. Without it the app claims "registered" for a device the OS silently
  /// drops every message from — measured on Android, where POST_NOTIFICATIONS
  /// was denied while both toggles were green and a token was registered.
  Widget _buildOsBlockedSection() {
    final denied = _osPermission == NotificationPermissionResult.permanentlyDenied;
    return CupertinoListSection.insetGrouped(
      header: const Text('DEVICE STATUS'),
      footer: Text(denied
          ? 'Notifications are turned off for RIVR in your device settings. '
              'Alerts will not appear on this device until you turn them on there.'
          : 'This device has not been asked yet. Turn a notification type off '
              'and on again to be prompted.'),
      children: [
        CupertinoListTile(
          leading: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: CupertinoColors.systemRed.resolveFrom(context),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(CupertinoIcons.bell_slash_fill,
                color: CupertinoColors.white, size: 17),
          ),
          title: Text(denied
              ? 'Blocked in device settings'
              : 'Permission not requested'),
          trailing: denied
              ? const CupertinoListTileChevron()
              : null,
          onTap: denied ? () => openAppSettings() : null,
        ),
      ],
    );
  }

  Widget _buildRegistrationStatusSection() {
    final tokens = _userSettings?.fcmTokens ?? [];
    final hasToken = tokens.isNotEmpty;
    final isPending = tokens.length == 1 && tokens.first == 'pending';

    final Color iconColor;
    final IconData icon;
    final String title;
    final String? subtitle;
    final String? footer;

    if (hasToken && !isPending) {
      iconColor = CupertinoColors.systemGreen;
      icon = CupertinoIcons.shield_fill;
      title = tokens.length == 1
          ? 'Device registered'
          : '${tokens.length} devices registered';
      final lastToken = tokens.last;
      subtitle = '...${lastToken.substring(lastToken.length - 8)}';
      footer = null;
    } else if (isPending) {
      iconColor = CupertinoColors.systemOrange;
      icon = CupertinoIcons.clock_fill;
      title = 'Registration pending';
      subtitle = 'Will activate on a real device';
      footer = null;
    } else {
      iconColor = CupertinoColors.systemRed;
      icon = CupertinoIcons.exclamationmark_triangle_fill;
      title = 'Device not registered';
      subtitle = null;
      footer = 'Try toggling notifications off and on again. '
          'If the issue persists, restart the app.';
    }

    return CupertinoListSection.insetGrouped(
      header: const Text('DEVICE STATUS'),
      footer: footer != null ? Text(footer) : null,
      children: [
        CupertinoListTile(
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: CupertinoColors.white, size: 18),
          ),
          title: Text(title),
          subtitle: subtitle != null ? Text(subtitle) : null,
        ),
      ],
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
                  // Off and inert while the OS refuses. Showing the account
                  // preference here would promise delivery this device cannot
                  // make; accepting a tap would persist a preference for a
                  // device that stays silent (ADR 0009, phase 3).
                  value: _osDenied ? false : _notificationsEnabled,
                  onChanged: _osDenied ? null : _toggleNotifications,
                ),
        ),
      ],
    );
  }

  Widget _buildDigestSection() {
    return CupertinoListSection.insetGrouped(
      header: const Text('DIGEST'),
      footer: const Text(
        'A calm weekly summary of how your favorite rivers are forecast to do — '
        'delivered even when nothing crosses a flood threshold. Independent from '
        'flood alerts; turn either off without affecting the other.',
      ),
      children: [
        CupertinoListTile(
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _weeklyOutlookEnabled
                  ? const Color(0xFF0E9BB3)
                  : CupertinoColors.systemGrey,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              CupertinoIcons.calendar,
              color: CupertinoColors.white,
              size: 18,
            ),
          ),
          title: const Text('Weekly Outlook'),
          trailing: _isUpdating
              ? const CupertinoActivityIndicator()
              : CupertinoSwitch(
                  value: _osDenied ? false : _weeklyOutlookEnabled,
                  onChanged: _osDenied ? null : _toggleWeeklyOutlook,
                ),
        ),
        if (_weeklyOutlookEnabled && !_osDenied)
          const CupertinoListTile(
            leading: SizedBox(width: 32),
            title: Text('Delivered'),
            additionalInfo: Text('Fridays, 7:00 AM'),
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
