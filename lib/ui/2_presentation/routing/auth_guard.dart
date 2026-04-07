// lib/ui/2_presentation/routing/auth_guard.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/2_presentation/features/auth/pages/auth_coordinator.dart';

/// Simple authentication guard for protecting routes
class AuthGuard extends StatelessWidget {
  final Widget child;
  final Widget? fallback;
  final VoidCallback? onRedirect;
  final bool requireAuth;

  const AuthGuard({
    super.key,
    required this.child,
    this.fallback,
    this.onRedirect,
    this.requireAuth = true,
  });

  /// Create an auth guard that requires authentication
  const AuthGuard.required({
    super.key,
    required this.child,
    this.fallback,
    this.onRedirect,
  }) : requireAuth = true;

  /// Create an auth guard that redirects if authenticated (for login/register pages)
  const AuthGuard.guest({
    super.key,
    required this.child,
    this.fallback,
    this.onRedirect,
  }) : requireAuth = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        // Show loading while auth provider is initializing
        if (!authProvider.isInitialized) {
          return _buildLoadingView();
        }

        final isAuthenticated = authProvider.isAuthenticated;

        // Handle authentication requirements
        if (requireAuth) {
          // Route requires authentication
          if (isAuthenticated) {
            return child; // User is authenticated, show protected content
          } else {
            return _handleUnauthenticated(context); // Redirect to auth
          }
        } else {
          // Route is for guests only (login/register pages)
          if (!isAuthenticated) {
            return child; // User is not authenticated, show guest content
          } else {
            return _handleAlreadyAuthenticated(context); // Redirect to main app
          }
        }
      },
    );
  }

  /// Handle unauthenticated user trying to access protected route
  Widget _handleUnauthenticated(BuildContext context) {
    AppLogger.debug('AuthGuard', 'Unauthenticated user accessing protected route');

    // Call redirect callback if provided
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onRedirect?.call();
    });

    // Show fallback or default auth screen
    return fallback ?? const AuthCoordinator();
  }

  /// Handle authenticated user trying to access guest-only route
  Widget _handleAlreadyAuthenticated(BuildContext context) {
    AppLogger.debug('AuthGuard', 'Authenticated user accessing guest route');

    // Call redirect callback if provided
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onRedirect?.call();
    });

    // Show fallback or redirect to main app
    return fallback ?? _buildAlreadyAuthenticatedView(context);
  }

  /// Loading view while checking authentication
  Widget _buildLoadingView() {
    return const CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CupertinoActivityIndicator(radius: 20),
            SizedBox(height: 20),
            Text(
              'Checking authentication...',
              style: TextStyle(fontSize: 16, color: CupertinoColors.systemGrey),
            ),
          ],
        ),
      ),
    );
  }

  /// Default view for already authenticated users
  Widget _buildAlreadyAuthenticatedView(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  CupertinoIcons.checkmark_circle,
                  size: 80,
                  color: CupertinoColors.systemGreen,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Already Signed In',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                const Text(
                  'You are already authenticated.',
                  style: TextStyle(
                    fontSize: 16,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
                const SizedBox(height: 30),
                CupertinoButton.filled(
                  onPressed: () {
                    // Navigate back or to main app
                    Navigator.of(context).pop();
                  },
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Utility class for common auth guard patterns
class AuthGuards {
  /// Protect a route that requires authentication
  static Widget protect(Widget child, {Widget? fallback}) {
    return AuthGuard.required(fallback: fallback, child: child);
  }

  /// Protect a route for guests only (redirect if authenticated)
  static Widget guestOnly(Widget child, {Widget? fallback}) {
    return AuthGuard.guest(fallback: fallback, child: child);
  }

  /// Create auth guard with custom redirect handling
  static Widget custom({
    required Widget child,
    required bool requireAuth,
    Widget? fallback,
    VoidCallback? onRedirect,
  }) {
    return AuthGuard(
      requireAuth: requireAuth,
      fallback: fallback,
      onRedirect: onRedirect,
      child: child,
    );
  }
}

/// Extension for easier route protection
extension RouteProtection on Widget {
  /// Wrap this widget with authentication protection
  Widget requireAuth({Widget? fallback, VoidCallback? onRedirect}) {
    return AuthGuard.required(
      fallback: fallback,
      onRedirect: onRedirect,
      child: this,
    );
  }

  /// Wrap this widget for guests only (redirect if authenticated)
  Widget guestOnly({Widget? fallback, VoidCallback? onRedirect}) {
    return AuthGuard.guest(
      fallback: fallback,
      onRedirect: onRedirect,
      child: this,
    );
  }
}
