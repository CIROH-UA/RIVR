// lib/ui/2_presentation/features/auth/pages/auth_coordinator.dart

import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/services/1_contracts/shared/i_cache_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/2_presentation/features/auth/pages/auth_wrapper.dart';

/// Main authentication flow coordinator for RIVR
class AuthCoordinator extends StatefulWidget {
  final Widget Function(BuildContext context)? onAuthSuccess;
  final VoidCallback? onAuthFailure;
  final AuthPageType initialPage;

  const AuthCoordinator({
    super.key,
    this.onAuthSuccess,
    this.onAuthFailure,
    this.initialPage = AuthPageType.login,
  });

  @override
  State<AuthCoordinator> createState() => _AuthCoordinatorState();
}

class _AuthCoordinatorState extends State<AuthCoordinator> {
  bool _isInitializing = true;
  String? _initializationError;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  /// Initialize all required services
  Future<void> _initializeServices() async {
    try {
      AppLogger.debug('AuthCoordinator', 'Initializing services...');

      // Initialize cache service
      await GetIt.I<ICacheService>().initialize();

      if (!mounted) return;

      // Initialize auth provider
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      await authProvider.initialize();

      AppLogger.info('AuthCoordinator', 'Services initialized successfully');

      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    } catch (e) {
      AppLogger.error('AuthCoordinator', 'Error initializing services: $e', e);

      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initializationError = 'Failed to initialize app: ${e.toString()}';
        });
      }
    }
  }

  /// Handle successful authentication
  Future<void> _handleAuthSuccess(AuthProvider authProvider) async {
    try {
      AppLogger.debug(
        'AuthCoordinator',
        'Handling auth success for user: ${authProvider.currentUser?.uid}',
      );

      if (authProvider.currentUser == null) {
        AppLogger.warning('AuthCoordinator', 'No current user found');
        return;
      }

      final userId = authProvider.currentUser!.uid;

      // Store auth data in cache
      await GetIt.I<ICacheService>().storeAuthData(
        userId: userId,
        email: authProvider.currentUser!.email,
      );

      // Sync user settings after login
      try {
        await GetIt.I<IUserSettingsService>().syncAfterLogin(userId);
        AppLogger.info('AuthCoordinator', 'User settings synced successfully');
      } catch (e) {
        AppLogger.warning('AuthCoordinator', 'Failed to sync user settings: $e');
        // Don't block auth success for settings sync failure
      }

      AppLogger.info('AuthCoordinator', 'Auth success handling completed');
    } catch (e) {
      AppLogger.error('AuthCoordinator', 'Error handling auth success: $e', e);
      // Don't block auth success for post-auth operations
    }
  }

  /// Handle authentication failure
  void _handleAuthFailure(AuthProvider authProvider) {
    AppLogger.warning(
      'AuthCoordinator',
      'Handling auth failure: ${authProvider.errorMessage}',
    );

    // Clear any cached auth data on failure
    GetIt.I<ICacheService>().clearAuthData();

    // Call optional failure callback
    widget.onAuthFailure?.call();
  }

  /// Handle sign out
  Future<void> _handleSignOut() async {
    try {
      AppLogger.debug('AuthCoordinator', 'Handling sign out');

      // Clear all cached data
      await GetIt.I<ICacheService>().clearEverything();

      // Clear user settings cache
      GetIt.I<IUserSettingsService>().clearCache();

      AppLogger.info('AuthCoordinator', 'Sign out completed');
    } catch (e) {
      AppLogger.error('AuthCoordinator', 'Error during sign out: $e', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show loading while initializing
    if (_isInitializing) {
      return const CupertinoPageScaffold(
        backgroundColor: CupertinoColors.systemGroupedBackground,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CupertinoActivityIndicator(radius: 20),
              SizedBox(height: 20),
              Text(
                'Initializing RIVR...',
                style: TextStyle(
                  fontSize: 16,
                  color: CupertinoColors.systemGrey,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Show error if initialization failed
    if (_initializationError != null) {
      return CupertinoPageScaffold(
        backgroundColor: CupertinoColors.systemGroupedBackground,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  CupertinoIcons.exclamationmark_triangle,
                  size: 60,
                  color: CupertinoColors.systemRed,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Initialization Failed',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Text(
                  _initializationError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
                const SizedBox(height: 30),
                CupertinoButton.filled(
                  onPressed: () {
                    setState(() {
                      _isInitializing = true;
                      _initializationError = null;
                    });
                    _initializeServices();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Main auth flow with state management
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        // Handle authentication state changes
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (authProvider.isAuthenticated) {
            _handleAuthSuccess(authProvider);
          } else if (authProvider.errorMessage.isNotEmpty) {
            _handleAuthFailure(authProvider);
          }
        });

        // Show authenticated content
        if (authProvider.isAuthenticated) {
          if (widget.onAuthSuccess != null) {
            return widget.onAuthSuccess!(context);
          } else {
            return _buildDefaultAuthenticatedView(authProvider);
          }
        }

        // Show authentication wrapper
        return AuthWrapper(
          initialPage: widget.initialPage,
          authenticatedChild: widget.onAuthSuccess != null
              ? widget.onAuthSuccess!(context)
              : _buildDefaultAuthenticatedView(authProvider),
        );
      },
    );
  }

  /// Default authenticated view when no custom content provided
  Widget _buildDefaultAuthenticatedView(AuthProvider authProvider) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('RIVR'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () async {
            await _handleSignOut();
            await authProvider.signOut();
          },
          child: Text(
            'Sign Out',
            style: TextStyle(
              color: CupertinoTheme.of(context).primaryColor,
              fontSize: 16,
            ),
          ),
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Welcome section
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      CupertinoTheme.of(context).primaryColor,
                      CupertinoTheme.of(context).primaryColor.withValues(alpha: 0.7),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: CupertinoTheme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  CupertinoIcons.checkmark_circle,
                  size: 50,
                  color: CupertinoColors.white,
                ),
              ),
              const SizedBox(height: 30),

              Text(
                'Welcome to RIVR!',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: CupertinoTheme.of(context).textTheme.textStyle.color,
                ),
              ),
              const SizedBox(height: 10),

              Text(
                'Hello ${authProvider.userDisplayName}',
                style: const TextStyle(
                  fontSize: 18,
                  color: CupertinoColors.systemGrey,
                ),
              ),
              const SizedBox(height: 40),

              // Info section
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 40),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey6,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    const Icon(
                      CupertinoIcons.info_circle,
                      size: 40,
                      color: CupertinoColors.systemBlue,
                    ),
                    const SizedBox(height: 15),
                    const Text(
                      'Authentication Complete',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Your authentication system is working perfectly! Replace this screen with your main app content.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: CupertinoColors.systemGrey2,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Quick actions
                    Row(
                      children: [
                        Expanded(
                          child: CupertinoButton.filled(
                            onPressed: () {
                              // Placeholder for main app navigation
                              showCupertinoDialog(
                                context: context,
                                builder: (context) => CupertinoAlertDialog(
                                  title: const Text('Ready for Main App'),
                                  content: const Text(
                                    'Replace this with navigation to your river monitoring features!',
                                  ),
                                  actions: [
                                    CupertinoDialogAction(
                                      child: const Text('OK'),
                                      onPressed: () =>
                                          Navigator.of(context).pop(),
                                    ),
                                  ],
                                ),
                              );
                            },
                            child: const Text('Get Started'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
