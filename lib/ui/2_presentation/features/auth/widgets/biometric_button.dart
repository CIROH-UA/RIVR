// lib/ui/2_presentation/features/auth/widgets/biometric_button.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

class BiometricButton extends StatefulWidget {
  final String text;
  final String loadingText;
  final Future<bool> Function()? onPressed;
  final bool enabled;

  const BiometricButton({
    super.key,
    this.text = 'Sign in with Touch ID',
    this.loadingText = 'Authenticating...',
    required this.onPressed,
    this.enabled = true,
  });

  @override
  State<BiometricButton> createState() => _BiometricButtonState();
}

class _BiometricButtonState extends State<BiometricButton> {
  bool _isLoading = false;
  bool _isAvailable = false;
  bool _isEnabled = false;
  bool _hasChecked = false;

  @override
  void initState() {
    super.initState();
    _checkBiometricCapabilities();
  }

  Future<void> _checkBiometricCapabilities() async {
    try {
      // This would normally get AuthProvider from context,
      // but for simplicity, we'll create a temporary instance
      final authProvider = AuthProvider();

      final available = await authProvider.isBiometricAvailable;
      final enabled = await authProvider.isBiometricEnabled;

      if (mounted) {
        setState(() {
          _isAvailable = available;
          _isEnabled = enabled;
          _hasChecked = true;
        });
      }
    } catch (e) {
      AppLogger.error('BiometricButton', 'Error checking biometric capabilities: $e', e);
      if (mounted) {
        setState(() {
          _isAvailable = false;
          _isEnabled = false;
          _hasChecked = true;
        });
      }
    }
  }

  Future<void> _handlePress() async {
    if (widget.onPressed == null || _isLoading || !widget.enabled) return;

    setState(() {
      _isLoading = true;
    });

    try {
      await widget.onPressed!();
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Don't show if not available or not checked yet
    if (!_hasChecked || !_isAvailable || !_isEnabled) {
      return const SizedBox.shrink();
    }

    final primaryColor = CupertinoTheme.of(context).primaryColor;

    final isDisabled = !widget.enabled || _isLoading;
    final borderColor = isDisabled ? CupertinoColors.systemGrey4 : primaryColor;
    final textColor = isDisabled ? CupertinoColors.systemGrey : primaryColor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SizedBox(
        width: double.infinity,
        height: 50,
        child: CupertinoButton(
          onPressed: isDisabled ? null : _handlePress,
          padding: EdgeInsets.zero,
          child: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              color: CupertinoColors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: 1.5),
            ),
            child: Center(
              child: _isLoading
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CupertinoActivityIndicator(
                            color: primaryColor,
                            radius: 8,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          widget.loadingText,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          CupertinoIcons.circle_grid_hex,
                          color: textColor,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.text,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
