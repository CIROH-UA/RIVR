// lib/features/auth/presentation/pages/register_page.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivrflow/features/auth/providers/auth_provider.dart';
import '../widgets/live_validation_field.dart';
import '../widgets/managed_async_button.dart';
import '../widgets/auth_error_display.dart';

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

  String? _validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Email is required';
    }
    if (!RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(value.trim())) {
      return 'Please enter a valid email';
    }
    return null;
  }

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
    final brightness = CupertinoTheme.brightnessOf(context);
    final primaryColor = CupertinoTheme.of(context).primaryColor;

    return CupertinoPageScaffold(
      backgroundColor: brightness == Brightness.dark
          ? CupertinoColors.black
          : CupertinoColors.systemGroupedBackground,
      child: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Consumer<AuthProvider>(
            builder: (context, authProvider, _) {
              return Column(
                children: [
                  const SizedBox(height: 40),

                  // App logo
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [primaryColor, primaryColor.withOpacity(0.7)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: primaryColor.withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      CupertinoIcons.drop_fill,
                      size: 40,
                      color: CupertinoColors.white,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Title
                  Text(
                    'Create Account',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: brightness == Brightness.dark
                          ? CupertinoColors.white
                          : CupertinoColors.black,
                    ),
                  ),
                  const SizedBox(height: 8),

                  Text(
                    'Join RIVR today',
                    style: TextStyle(
                      fontSize: 16,
                      color: brightness == Brightness.dark
                          ? CupertinoColors.systemGrey
                          : CupertinoColors.systemGrey2,
                    ),
                  ),
                  const SizedBox(height: 30),

                  // First name field
                  LiveValidationField(
                    controller: _firstNameController,
                    focusNode: _firstNameFocusNode,
                    placeholder: 'First Name',
                    keyboardType: TextInputType.name,
                    prefixIcon: CupertinoIcons.person,
                    validator: _validateName,
                    onChanged: (_) => authProvider.clearMessages(),
                  ),

                  // Last name field
                  LiveValidationField(
                    controller: _lastNameController,
                    focusNode: _lastNameFocusNode,
                    placeholder: 'Last Name',
                    keyboardType: TextInputType.name,
                    prefixIcon: CupertinoIcons.person,
                    validator: _validateName,
                    onChanged: (_) => authProvider.clearMessages(),
                  ),

                  // Email field
                  LiveValidationField(
                    controller: _emailController,
                    focusNode: _emailFocusNode,
                    placeholder: 'Email',
                    keyboardType: TextInputType.emailAddress,
                    prefixIcon: CupertinoIcons.mail,
                    validator: _validateEmail,
                    onChanged: (_) => authProvider.clearMessages(),
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
                    onChanged: (_) => authProvider.clearMessages(),
                  ),

                  // Confirm password field
                  LiveValidationField(
                    controller: _confirmPasswordController,
                    focusNode: _confirmPasswordFocusNode,
                    placeholder: 'Confirm Password',
                    obscureText: _obscureConfirmPassword,
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
                    onChanged: (_) => authProvider.clearMessages(),
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
                          color: brightness == Brightness.dark
                              ? CupertinoColors.systemGrey
                              : CupertinoColors.systemGrey2,
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
                  const SizedBox(height: 30),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
