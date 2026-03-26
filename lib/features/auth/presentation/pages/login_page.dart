// lib/features/auth/presentation/pages/login_page.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';
import '../widgets/live_validation_field.dart';
import '../widgets/managed_async_button.dart';
import '../widgets/auth_error_display.dart';
import '../widgets/biometric_button.dart';
import '../../utils/email_validator.dart';

class LoginPage extends StatefulWidget {
  final VoidCallback onSwitchToRegister;
  final VoidCallback onSwitchToForgotPassword;

  const LoginPage({
    super.key,
    required this.onSwitchToRegister,
    required this.onSwitchToForgotPassword,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) => validateEmail(value);

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }
    if (value.length < 6) {
      return 'Password must be at least 6 characters';
    }
    return null;
  }

  Future<void> _handleLogin() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    await authProvider.signIn(
      _emailController.text.trim(),
      _passwordController.text,
    );
  }

  Future<bool> _handleBiometricLogin() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    return await authProvider.signInWithBiometric();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = CupertinoTheme.of(context).primaryColor;

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Consumer<AuthProvider>(
                  builder: (context, authProvider, _) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          children: [
                            const SizedBox(height: 60),

                  // Title
                  Text(
                    'Welcome to',
                    style: TextStyle(
                      fontSize: 16,
                      color: CupertinoColors.systemGrey2,
                    ),
                  ),
                  const SizedBox(height: 4),

                  Text(
                    'RIVR',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      color: CupertinoColors.black,
                    ),
                  ),
                  const SizedBox(height: 40),

                  // Email field
                  LiveValidationField(
                    controller: _emailController,
                    focusNode: _emailFocusNode,
                    placeholder: 'Email',
                    keyboardType: TextInputType.emailAddress,
                    prefixIcon: CupertinoIcons.mail,
                    validator: _validateEmail,
                    onChanged: (_) {},
                  ),

                  // Password field
                  LiveValidationField(
                    controller: _passwordController,
                    focusNode: _passwordFocusNode,
                    placeholder: 'Password',
                    obscureText: _obscurePassword,
                    prefixIcon: CupertinoIcons.lock,
                    validator: _validatePassword,
                    suffixIcon: CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                      minimumSize: Size(0, 0),
                      child: Icon(
                        _obscurePassword
                            ? CupertinoIcons.eye_slash
                            : CupertinoIcons.eye,
                        color: CupertinoColors.systemGrey,
                        size: 20,
                      ),
                    ),
                    onChanged: (_) {},
                  ),
                  const SizedBox(height: 10),

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

                  const SizedBox(height: 10),

                  // Sign in button
                  ManagedAsyncButton(
                    text: 'Sign In',
                    loadingText: 'Signing in...',
                    onPressed: _handleLogin,
                    isEnabled: !authProvider.isLoading,
                    icon: CupertinoIcons.arrow_right,
                  ),
                  const SizedBox(height: 15),

                  // Biometric button
                  BiometricButton(
                    onPressed: _handleBiometricLogin,
                    enabled: !authProvider.isLoading,
                  ),
                  const SizedBox(height: 25),

                  // Forgot password
                  CupertinoButton(
                    onPressed: widget.onSwitchToForgotPassword,
                    child: Text(
                      'Forgot Password?',
                      style: TextStyle(
                        color: primaryColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),

                  // Register link
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Don't have an account? ",
                        style: TextStyle(
                          color: CupertinoColors.systemGrey2,
                          fontSize: 16,
                        ),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: widget.onSwitchToRegister,
                        minimumSize: Size(0, 0),
                        child: Text(
                          'Sign Up',
                          style: TextStyle(
                            color: primaryColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                          ],
                        ),
                        // Terms of Service & Privacy Policy
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 32,
                            right: 32,
                            bottom: 30,
                            top: 16,
                          ),
                          child: Text.rich(
                            TextSpan(
                              style: TextStyle(
                                fontSize: 12,
                                color: CupertinoColors.systemGrey,
                              ),
                              children: [
                                const TextSpan(
                                    text:
                                        'By continuing, you agree to our '),
                                TextSpan(
                                  text: 'Terms of Service',
                                  style: TextStyle(color: primaryColor),
                                  recognizer: TapGestureRecognizer()
                                    ..onTap = () => launchUrl(
                                          Uri.parse(
                                              'https://www.hydromap.com'),
                                          mode:
                                              LaunchMode.externalApplication,
                                        ),
                                ),
                                const TextSpan(text: ' and '),
                                TextSpan(
                                  text: 'Privacy Policy',
                                  style: TextStyle(color: primaryColor),
                                  recognizer: TapGestureRecognizer()
                                    ..onTap = () => launchUrl(
                                          Uri.parse(
                                              'https://www.hydromap.com'),
                                          mode:
                                              LaunchMode.externalApplication,
                                        ),
                                ),
                                const TextSpan(text: '. v1.0.0'),
                              ],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
