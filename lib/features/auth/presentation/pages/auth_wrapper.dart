// lib/features/auth/presentation/pages/auth_wrapper.dart

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:rivr/features/auth/providers/auth_provider.dart';
import 'login_page.dart';
import 'register_page.dart';
import 'forgot_password_page.dart';
import 'email_verification_page.dart';

enum AuthPageType { login, register, forgotPassword, emailVerification }

class AuthWrapper extends StatefulWidget {
  final Widget? authenticatedChild;
  final AuthPageType initialPage;

  const AuthWrapper({
    super.key,
    this.authenticatedChild,
    this.initialPage = AuthPageType.login,
  });

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  late AuthPageType _currentPage;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
  }

  void _switchToPage(AuthPageType page) {
    if (_currentPage == page) return;
    context.read<AuthProvider>().clearMessages();
    setState(() => _currentPage = page);
  }

  void _switchToLogin() => _switchToPage(AuthPageType.login);
  void _switchToRegister() => _switchToPage(AuthPageType.register);
  void _switchToForgotPassword() => _switchToPage(AuthPageType.forgotPassword);

  Widget _buildCurrentPage() {
    switch (_currentPage) {
      case AuthPageType.login:
        return LoginPage(
          onSwitchToRegister: _switchToRegister,
          onSwitchToForgotPassword: _switchToForgotPassword,
        );
      case AuthPageType.register:
        return RegisterPage(onSwitchToLogin: _switchToLogin);
      case AuthPageType.forgotPassword:
        return ForgotPasswordPage(onBackToLogin: _switchToLogin);
      case AuthPageType.emailVerification:
        return EmailVerificationPage(
          onSignOut: () async {
            final authProvider =
                Provider.of<AuthProvider>(context, listen: false);
            await authProvider.signOut();
            _switchToRegister();
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        // Show loading while initializing
        if (!authProvider.isInitialized) {
          return const CupertinoPageScaffold(
            child: Center(child: CupertinoActivityIndicator(radius: 20)),
          );
        }

        // Show verification page if awaiting email verification
        if (authProvider.isAwaitingEmailVerification) {
          return EmailVerificationPage(
            onSignOut: () async {
              await authProvider.signOut();
              _switchToRegister();
            },
          );
        }

        // Show authenticated content if user is signed in
        if (authProvider.isAuthenticated) {
          return widget.authenticatedChild ?? _buildDefaultAuthenticatedView();
        }

        // Show authentication pages with crossfade transition
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              fit: StackFit.expand,
              children: [
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            );
          },
          child: KeyedSubtree(
            key: ValueKey(_currentPage),
            child: _buildCurrentPage(),
          ),
        );
      },
    );
  }

  Widget _buildDefaultAuthenticatedView() {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('RIVR'),
        trailing: Consumer<AuthProvider>(
          builder: (context, authProvider, _) {
            return CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => authProvider.signOut(),
              child: Text(
                'Sign Out',
                style: TextStyle(
                  color: CupertinoTheme.of(context).primaryColor,
                  fontSize: 16,
                ),
              ),
            );
          },
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Consumer<AuthProvider>(
            builder: (context, authProvider, _) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    CupertinoIcons.checkmark_circle,
                    size: 80,
                    color: CupertinoColors.systemGreen,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Welcome back!',
                    style: CupertinoTheme.of(
                      context,
                    ).textTheme.navLargeTitleTextStyle,
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
                  const CupertinoActivityIndicator(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
