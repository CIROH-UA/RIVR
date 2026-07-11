// lib/ui/2_presentation/features/profile/pages/account_page.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Account screen.
///
/// Intentionally narrow: identity (initials avatar, name, email, member-since)
/// plus the two account actions — Sign Out and Delete Account (App Store
/// Guideline 5.1.1(v)). Preferences and notifications deliberately live in the
/// three-dots menu and are NOT duplicated here.
class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Account'),
      ),
      child: SafeArea(
        child: Consumer<AuthProvider>(
          builder: (context, auth, _) {
            return ListView(
              children: [
                const SizedBox(height: 24),
                _IdentityHeader(auth: auth),
                const SizedBox(height: 24),
                _SignOutSection(auth: auth),
                _DeleteAccountSection(auth: auth),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ── Identity header ──────────────────────────────────────────────────────────

class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({required this.auth});
  final AuthProvider auth;

  String get _initials {
    final f = auth.userFirstName.trim();
    final l = auth.userLastName.trim();
    if (f.isNotEmpty && l.isNotEmpty) {
      return '${f[0]}${l[0]}'.toUpperCase();
    }
    if (f.isNotEmpty) return f[0].toUpperCase();
    final email = auth.currentUserEmail;
    return email.isNotEmpty ? email[0].toUpperCase() : '?';
  }

  String? get _memberSince {
    final created = auth.currentUser?.createdAt;
    if (created == null) return null;
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return 'Member since ${months[created.month - 1]} ${created.year}';
  }

  @override
  Widget build(BuildContext context) {
    final emailVerified = auth.currentUser?.isEmailVerified ?? false;
    final memberSince = _memberSince;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: CupertinoColors.systemBlue,
            ),
            alignment: Alignment.center,
            child: Text(
              _initials,
              style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 34,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            auth.userFullName,
            style: const TextStyle(
              fontSize: 22,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  auth.currentUserEmail,
                  style: const TextStyle(
                    fontSize: 15,
                    color: CupertinoColors.systemGrey,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                emailVerified
                    ? CupertinoIcons.checkmark_seal_fill
                    : CupertinoIcons.exclamationmark_circle,
                size: 16,
                color: emailVerified
                    ? CupertinoColors.systemGreen
                    : CupertinoColors.systemOrange,
                semanticLabel:
                    emailVerified ? 'Email verified' : 'Email not verified',
              ),
            ],
          ),
          if (memberSince != null) ...[
            const SizedBox(height: 4),
            Text(
              memberSince,
              style: const TextStyle(
                fontSize: 13,
                color: CupertinoColors.systemGrey2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Sign out ─────────────────────────────────────────────────────────────────

class _SignOutSection extends StatelessWidget {
  const _SignOutSection({required this.auth});
  final AuthProvider auth;

  Future<void> _confirmSignOut(BuildContext context) async {
    final shouldSignOut = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out of RIVR?'),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Sign Out'),
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );

    if (shouldSignOut == true) {
      await auth.signOut();
      // AuthCoordinator (the root route) rebuilds to show the login flow,
      // but this pushed Account route still sits on top of it. Pop back to
      // the root so the login screen is actually visible.
      if (context.mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoListSection.insetGrouped(
      children: [
        CupertinoListTile(
          title: Text(
            'Sign Out',
            style: TextStyle(
              color: auth.isLoading
                  ? CupertinoColors.systemGrey
                  : CupertinoColors.label,
            ),
          ),
          leading: const Icon(
            CupertinoIcons.square_arrow_right,
            color: CupertinoColors.systemGrey,
          ),
          onTap: auth.isLoading ? null : () => _confirmSignOut(context),
        ),
      ],
    );
  }
}

// ── Delete account ───────────────────────────────────────────────────────────

class _DeleteAccountSection extends StatelessWidget {
  const _DeleteAccountSection({required this.auth});
  final AuthProvider auth;

  Future<void> _handleDeleteAccount(BuildContext context) async {
    final passwordController = TextEditingController();
    final password = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('Delete Account'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            children: [
              const Text(
                'This permanently deletes your account, saved rivers, '
                'notification settings, and all associated data. This cannot '
                'be undone.\n\nEnter your password to confirm.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: passwordController,
                placeholder: 'Current password',
                obscureText: true,
                autofocus: true,
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(dialogContext, null),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Delete'),
            onPressed: () =>
                Navigator.pop(dialogContext, passwordController.text),
          ),
        ],
      ),
    );
    passwordController.dispose();

    if (password == null || !context.mounted) return;

    final ok = await auth.deleteAccount(password);
    if (!context.mounted) return;

    if (ok) {
      // Auth-state stream drops the user; the root AuthCoordinator rebuilds
      // to the login flow. Pop back to root so this pushed route isn't left
      // covering it.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      AppLogger.warning(
        'AccountPage',
        'Account deletion failed: ${auth.errorMessage}',
      );
      showCupertinoDialog(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('Deletion Failed'),
          content: Text(
            auth.errorMessage.isNotEmpty
                ? auth.errorMessage
                : 'Something went wrong. Please try again.',
          ),
          actions: [
            CupertinoDialogAction(
              child: const Text('OK'),
              onPressed: () => Navigator.pop(dialogContext),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Explanation goes BEFORE the button (section header), not after.
    // No red text, no "danger zone" — only the trash icon is red.
    return CupertinoListSection.insetGrouped(
      header: const Text(
        'Deleting your account is permanent and cannot be undone. All your '
        'data — saved rivers, preferences, and notifications — is removed.',
        style: TextStyle(
          fontWeight: FontWeight.normal,
          fontSize: 13,
          color: CupertinoColors.secondaryLabel,
        ),
      ),
      children: [
        CupertinoListTile(
          title: Text(
            'Delete Account',
            style: TextStyle(
              color: auth.isLoading
                  ? CupertinoColors.systemGrey
                  : CupertinoColors.label,
            ),
          ),
          leading: const Icon(
            CupertinoIcons.trash,
            color: CupertinoColors.systemRed,
          ),
          onTap: auth.isLoading ? null : () => _handleDeleteAccount(context),
        ),
      ],
    );
  }
}
