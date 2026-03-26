// lib/features/auth/presentation/pages/register_page.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';
import '../widgets/live_validation_field.dart';
import '../widgets/managed_async_button.dart';
import '../widgets/auth_error_display.dart';
import '../widgets/password_strength_indicator.dart';
import '../../utils/email_validator.dart';

class RegisterPage extends StatefulWidget {
  final VoidCallback onSwitchToLogin;

  const RegisterPage({super.key, required this.onSwitchToLogin});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  final _firstNameFocusNode = FocusNode();
  final _lastNameFocusNode = FocusNode();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _firstNameFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();

    _firstNameFocusNode.dispose();
    _lastNameFocusNode.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    super.dispose();
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'This field is required';
    }
    if (value.trim().length < 2) {
      return 'Must be at least 2 characters';
    }
    return null;
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

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your password';
    }
    if (value != _passwordController.text) {
      return 'Passwords do not match';
    }
    return null;
  }

  Future<void> _handleRegister() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    await authProvider.register(
      email: _emailController.text.trim(),
      password: _passwordController.text,
      firstName: _firstNameController.text.trim(),
      lastName: _lastNameController.text.trim(),
    );
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
                            const SizedBox(height: 40),

                  // Title
                  Text(
                    'Create your',
                    style: TextStyle(
                      fontSize: 16,
                      color: CupertinoColors.systemGrey2,
                    ),
                  ),
                  const SizedBox(height: 4),

                  Text(
                    'RIVR Account',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      color: CupertinoColors.black,
                    ),
                  ),
                  const SizedBox(height: 30),

                  // First name field
                  LiveValidationField(
                    controller: _firstNameController,
                    focusNode: _firstNameFocusNode,
                    placeholder: 'First Name',
                    keyboardType: TextInputType.name,
                    textInputAction: TextInputAction.next,
                    prefixIcon: CupertinoIcons.person,
                    validator: _validateName,
                    onChanged: (_) {},
                    onSubmitted: (_) =>
                        _lastNameFocusNode.requestFocus(),
                  ),

                  // Last name field
                  LiveValidationField(
                    controller: _lastNameController,
                    focusNode: _lastNameFocusNode,
                    placeholder: 'Last Name',
                    keyboardType: TextInputType.name,
                    textInputAction: TextInputAction.next,
                    prefixIcon: CupertinoIcons.person,
                    validator: _validateName,
                    onChanged: (_) {},
                    onSubmitted: (_) =>
                        _emailFocusNode.requestFocus(),
                  ),

                  // Email field
                  LiveValidationField(
                    controller: _emailController,
                    focusNode: _emailFocusNode,
                    placeholder: 'Email',
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    prefixIcon: CupertinoIcons.mail,
                    validator: _validateEmail,
                    onChanged: (_) {},
                    onSubmitted: (_) =>
                        _passwordFocusNode.requestFocus(),
                  ),

                  // Password field
                  LiveValidationField(
                    controller: _passwordController,
                    focusNode: _passwordFocusNode,
                    placeholder: 'Password',
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.next,
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
                    onSubmitted: (_) =>
                        _confirmPasswordFocusNode.requestFocus(),
                  ),

                  // Password strength indicator
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _passwordController,
                    builder: (context, value, _) {
                      return PasswordStrengthIndicator(
                        password: value.text,
                      );
                    },
                  ),

                  // Confirm password field
                  LiveValidationField(
                    controller: _confirmPasswordController,
                    focusNode: _confirmPasswordFocusNode,
                    placeholder: 'Confirm Password',
                    obscureText: _obscureConfirmPassword,
                    textInputAction: TextInputAction.done,
                    prefixIcon: CupertinoIcons.lock_shield,
                    validator: _validateConfirmPassword,
                    suffixIcon: CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        setState(() {
                          _obscureConfirmPassword = !_obscureConfirmPassword;
                        });
                      },
                      minimumSize: Size(0, 0),
                      child: Icon(
                        _obscureConfirmPassword
                            ? CupertinoIcons.eye_slash
                            : CupertinoIcons.eye,
                        color: CupertinoColors.systemGrey,
                        size: 20,
                      ),
                    ),
                    onChanged: (_) {},
                    onSubmitted: (_) => _handleRegister(),
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

                  // Register button
                  ManagedAsyncButton(
                    text: 'Create Account',
                    loadingText: 'Creating account...',
                    onPressed: _handleRegister,
                    isEnabled: !authProvider.isLoading,
                    icon: CupertinoIcons.add,
                  ),
                  const SizedBox(height: 30),

                  // Login link
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Already have an account? ',
                        style: TextStyle(
                          color: CupertinoColors.systemGrey2,
                          fontSize: 16,
                        ),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: widget.onSwitchToLogin,
                        minimumSize: Size(0, 0),
                        child: Text(
                          'Sign In',
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
                                        'By creating an account, you agree to our '),
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
