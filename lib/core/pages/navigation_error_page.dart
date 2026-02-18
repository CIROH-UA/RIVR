// lib/core/pages/navigation_error_page.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/core/routing/app_router.dart';

/// Reusable error page for navigation and route errors
/// Provides user-friendly error messages and navigation recovery
class NavigationErrorPage extends StatelessWidget {
  final String message;
  final String? title;
  final IconData? icon;
  final String? actionText;
  final VoidCallback? onAction;

  const NavigationErrorPage({
    super.key,
    required this.message,
    this.title,
    this.icon,
    this.actionText,
    this.onAction,
  });

  /// Common error for missing route arguments
  const NavigationErrorPage.missingArguments({
    super.key,
    required String routeName,
  }) : message = 'Missing required data for $routeName page.',
       title = 'Navigation Error',
       icon = CupertinoIcons.exclamationmark_triangle,
       actionText = null,
       onAction = null;

  /// Common error for invalid route arguments
  const NavigationErrorPage.invalidArguments({
    super.key,
    required String expected,
    required String routeName,
  }) : message =
           'Invalid data provided for $routeName page.\nExpected: $expected',
       title = 'Navigation Error',
       icon = CupertinoIcons.exclamationmark_triangle,
       actionText = null,
       onAction = null;

  /// Common error for page not found
  const NavigationErrorPage.pageNotFound({super.key, required String routeName})
    : message = 'The requested page "$routeName" could not be found.',
      title = 'Page Not Found',
      icon = CupertinoIcons.question_circle,
      actionText = null,
      onAction = null;

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(title ?? 'Error'),
        leading: _buildBackButton(context),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Error icon
              Icon(
                icon ?? CupertinoIcons.exclamationmark_triangle,
                size: 64,
                color: _getIconColor(),
              ),

              const SizedBox(height: 24),

              // Error title
              Text(
                title ?? 'Something went wrong',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 12),

              // Error message
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),

              const SizedBox(height: 32),

              // Action buttons
              _buildActionButtons(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _buildBackButton(BuildContext context) {
    // Only show back button if we can actually go back
    if (Navigator.of(context).canPop()) {
      return CupertinoNavigationBarBackButton(
        onPressed: () => Navigator.of(context).pop(),
      );
    }
    return null;
  }

  Widget _buildActionButtons(BuildContext context) {
    return Column(
      children: [
        // Custom action button (if provided)
        if (onAction != null) ...[
          SizedBox(
            width: double.infinity,
            child: CupertinoButton.filled(
              onPressed: onAction,
              child: Text(actionText ?? 'Try Again'),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Go Home button
        SizedBox(
          width: double.infinity,
          child: CupertinoButton.filled(
            onPressed: () => _navigateHome(context),
            child: const Text('Go Home'),
          ),
        ),

        // Back button (if navigation stack allows)
        if (Navigator.of(context).canPop()) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go Back'),
            ),
          ),
        ],
      ],
    );
  }

  Color _getIconColor() {
    switch (icon) {
      case CupertinoIcons.question_circle:
        return CupertinoColors.systemBlue;
      case CupertinoIcons.info_circle:
        return CupertinoColors.systemBlue;
      case CupertinoIcons.checkmark_circle:
        return CupertinoColors.systemGreen;
      case CupertinoIcons.exclamationmark_triangle:
      default:
        return CupertinoColors.systemRed;
    }
  }

  void _navigateHome(BuildContext context) {
    // Navigate to favorites page (home) and clear the stack
    AppRouter.pushFavoritesAndClear(context);
  }
}
