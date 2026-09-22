// lib/ui/2_presentation/features/auth/widgets/guest_account_prompt.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/2_presentation/routing/app_router.dart';

/// The one "create an account" prompt (ADR 0014 UX-3).
///
/// Shown to a guest once, after their first favourite is saved. It is a
/// sheet with a Not now, never a blocking dialog, and it is recorded on the
/// user document so a reinstall that keeps the uid does not repeat it.
class GuestAccountPrompt {
  GuestAccountPrompt._();

  static Future<void> maybeShow(BuildContext context) async {
    final auth = context.read<AuthProvider>();
    if (!auth.shouldShowAccountPrompt) return;
    // Mark first: if the sheet is dismissed by a route change we still never
    // show it twice.
    await auth.markAccountPromptShown();
    if (!context.mounted) return;

    final create = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Saved'),
        message: const Text(
          'Create an account to keep your rivers and alerts if you change '
          'phones. Everything else works without one.',
        ),
        actions: [
          CupertinoActionSheetAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create an account'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now'),
        ),
      ),
    );
    if (create == true && context.mounted) {
      await AppRouter.pushCreateAccount(context);
    }
  }
}
