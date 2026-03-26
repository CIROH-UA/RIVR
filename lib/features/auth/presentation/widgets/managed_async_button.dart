// lib/features/auth/presentation/widgets/managed_async_button.dart

import 'package:flutter/cupertino.dart';

class ManagedAsyncButton extends StatefulWidget {
  final String text;
  final String loadingText;
  final Future<void> Function()? onPressed;
  final Color? color;
  final Color? textColor;
  final bool isEnabled;
  final IconData? icon;
  final double height;

  const ManagedAsyncButton({
    super.key,
    required this.text,
    this.loadingText = 'Please wait...',
    required this.onPressed,
    this.color,
    this.textColor,
    this.isEnabled = true,
    this.icon,
    this.height = 50,
  });

  @override
  State<ManagedAsyncButton> createState() => _ManagedAsyncButtonState();
}

class _ManagedAsyncButtonState extends State<ManagedAsyncButton> {
  bool _isLoading = false;

  Future<void> _handlePress() async {
    if (widget.onPressed == null || _isLoading || !widget.isEnabled) return;

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
    final primaryColor = CupertinoTheme.of(context).primaryColor;

    final buttonColor = widget.color ?? primaryColor;
    final textColor = widget.textColor ?? CupertinoColors.white;

    final isDisabled = !widget.isEnabled || _isLoading;
    final displayColor = isDisabled
        ? CupertinoColors.systemGrey5.color
        : buttonColor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SizedBox(
        width: double.infinity,
        height: widget.height,
        child: CupertinoButton(
          onPressed: isDisabled ? null : _handlePress,
          padding: EdgeInsets.zero,
          child: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              color: _isLoading ? buttonColor.withValues(alpha: 0.7) : displayColor,
              borderRadius: BorderRadius.circular(10),
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
                            color: textColor,
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
                        if (widget.icon != null) ...[
                          Icon(
                            widget.icon,
                            color: isDisabled
                                ? CupertinoColors.systemGrey3
                                : textColor,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          widget.text,
                          style: TextStyle(
                            color: isDisabled
                                ? CupertinoColors.systemGrey3
                                : textColor,
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
