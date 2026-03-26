// lib/features/auth/presentation/pages/forgot_password_page.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';
import '../widgets/live_validation_field.dart';
import '../widgets/managed_async_button.dart';
import '../widgets/auth_error_display.dart';
import '../../utils/email_validator.dart';

class ForgotPasswordPage extends StatefulWidget {
  final VoidCallback onBackToLogin;

  const ForgotPasswordPage({super.key, required this.onBackToLogin});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _emailController = TextEditingController();
  final _emailFocusNode = FocusNode();
  bool _emailSent = false;

  @override
  void dispose() {
    _emailController.dispose();
    _emailFocusNode.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) => validateEmail(value);

  Future<void> _handleSendReset() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final success = await authProvider.sendPasswordReset(
      _emailController.text.trim(),
    );

    if (success) {
      setState(() {
        _emailSent = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = CupertinoTheme.of(context).primaryColor;

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.systemGroupedBackground,
        border: null,
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: widget.onBackToLogin,
          child: Icon(CupertinoIcons.back, color: primaryColor),
        ),
        middle: const Text('Reset Password'),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Consumer<AuthProvider>(
            builder: (context, authProvider, _) {
              if (_emailSent && authProvider.successMessage.isNotEmpty) {
                // Success state
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const SizedBox(height: 80),

                      // Success icon
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGreen.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(40),
                          border: Border.all(
                            color: CupertinoColors.systemGreen.withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          CupertinoIcons.checkmark_circle,
                          size: 40,
                          color: CupertinoColors.systemGreen,
                        ),
                      ),
                      const SizedBox(height: 30),

                      // Success message
                      Text(
                        'Email Sent!',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: CupertinoColors.black,
                        ),
                      ),
                      const SizedBox(height: 15),

                      Text(
                        'Check your email for password reset instructions. If you don\'t see it, check your spam folder.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: CupertinoColors.systemGrey2,
                        ),
                      ),
                      const SizedBox(height: 40),

                      // Back to login button
                      ManagedAsyncButton(
                        text: 'Back to Sign In',
                        onPressed: () async => widget.onBackToLogin(),
                        icon: CupertinoIcons.arrow_left,
                      ),
                      const SizedBox(height: 20),

                      // Send another email
                      CupertinoButton(
                        onPressed: () {
                          setState(() {
                            _emailSent = false;
                          });
                          authProvider.clearMessages();
                        },
                        child: Text(
                          'Send Another Email',
                          style: TextStyle(color: primaryColor, fontSize: 16),
                        ),
                      ),
                    ],
                  ),
                );
              }

              // Form state
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const SizedBox(height: 60),

                    // Reset icon
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(40),
                        border: Border.all(
                          color: primaryColor.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        CupertinoIcons.lock_rotation,
                        size: 40,
                        color: primaryColor,
                      ),
                    ),
                    const SizedBox(height: 30),

                    // Title
                    Text(
                      'Reset Your Password',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: CupertinoColors.black,
                      ),
                    ),
                    const SizedBox(height: 15),

                    Text(
                      'Enter your email address and we\'ll send you instructions to reset your password.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: CupertinoColors.systemGrey2,
                      ),
                    ),
                    const SizedBox(height: 40),

                    // Email field
                    LiveValidationField(
                      controller: _emailController,
                      focusNode: _emailFocusNode,
                      placeholder: 'Enter your email',
                      keyboardType: TextInputType.emailAddress,
                      prefixIcon: CupertinoIcons.mail,
                      validator: _validateEmail,
                      onChanged: (_) => authProvider.clearMessages(),
                    ),
                    const SizedBox(height: 15),

                    // Error display
                    if (authProvider.errorMessage.isNotEmpty)
                      AuthErrorDisplay.error(
                        message: authProvider.errorMessage,
                        onDismiss: authProvider.clearMessages,
                      ),

                    const SizedBox(height: 10),

                    // Send reset button
                    ManagedAsyncButton(
                      text: 'Send Reset Email',
                      loadingText: 'Sending...',
                      onPressed: _handleSendReset,
                      isEnabled: !authProvider.isLoading,
                      icon: CupertinoIcons.paperplane,
                    ),
                    const SizedBox(height: 30),

                    // Back to login
                    CupertinoButton(
                      onPressed: widget.onBackToLogin,
                      child: Text(
                        'Back to Sign In',
                        style: TextStyle(color: primaryColor, fontSize: 16),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
