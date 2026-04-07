// lib/ui/2_presentation/features/auth/pages/email_verification_page.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/ui/2_presentation/features/auth/widgets/managed_async_button.dart';
import 'package:rivr/ui/2_presentation/features/auth/widgets/auth_error_display.dart';

class EmailVerificationPage extends StatelessWidget {
  final VoidCallback onSignOut;

  const EmailVerificationPage({super.key, required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    final primaryColor = CupertinoTheme.of(context).primaryColor;

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      child: SafeArea(
        child: Consumer<AuthProvider>(
          builder: (context, authProvider, _) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(flex: 2),

                  // Mail icon
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: primaryColor.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      CupertinoIcons.mail,
                      size: 48,
                      color: primaryColor,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Title
                  Text(
                    'Verify your email',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: CupertinoColors.black,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Subtitle with email
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'We sent a verification link to ${authProvider.currentUserEmail}. Check your inbox and tap the link to continue.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: CupertinoColors.systemGrey2,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Spam folder hint
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          CupertinoIcons.info_circle,
                          size: 14,
                          color: CupertinoColors.systemGrey,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "Don't see it? Check your spam folder.",
                          style: TextStyle(
                            fontSize: 13,
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Error/Success display
                  if (authProvider.errorMessage.isNotEmpty)
                    AuthErrorDisplay.error(
                      message: authProvider.errorMessage,
                      onDismiss: authProvider.clearMessages,
                    ),

                  if (authProvider.successMessage.isNotEmpty)
                    AuthErrorDisplay.success(
                      message: authProvider.successMessage,
                    ),

                  const SizedBox(height: 16),

                  // "I've Verified" button
                  ManagedAsyncButton(
                    text: "I've Verified My Email",
                    loadingText: 'Checking...',
                    onPressed: () async {
                      await authProvider.checkEmailVerified();
                    },
                    isEnabled: !authProvider.isLoading,
                    icon: CupertinoIcons.checkmark_circle,
                  ),
                  const SizedBox(height: 12),

                  // "Resend Email" button
                  CupertinoButton(
                    onPressed: authProvider.isLoading
                        ? null
                        : () => authProvider.sendVerificationEmail(),
                    child: Text(
                      'Resend Verification Email',
                      style: TextStyle(
                        color: primaryColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),

                  const Spacer(flex: 3),

                  // "Use a different email" link
                  Padding(
                    padding: const EdgeInsets.only(bottom: 40),
                    child: CupertinoButton(
                      onPressed: onSignOut,
                      child: Text(
                        'Use a different email',
                        style: TextStyle(
                          color: CupertinoColors.systemGrey,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
