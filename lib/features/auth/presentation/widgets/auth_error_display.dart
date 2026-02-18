// lib/features/auth/presentation/widgets/auth_error_display.dart

import 'package:flutter/cupertino.dart';

enum MessageType { error, success, info }

class AuthErrorDisplay extends StatelessWidget {
  final String message;
  final MessageType type;
  final VoidCallback? onDismiss;

  const AuthErrorDisplay({
    super.key,
    required this.message,
    this.type = MessageType.error,
    this.onDismiss,
  });

  const AuthErrorDisplay.error({
    super.key,
    required this.message,
    this.onDismiss,
  }) : type = MessageType.error;

  const AuthErrorDisplay.success({
    super.key,
    required this.message,
    this.onDismiss,
  }) : type = MessageType.success;

  const AuthErrorDisplay.info({
    super.key,
    required this.message,
    this.onDismiss,
  }) : type = MessageType.info;

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return const SizedBox.shrink();

    final (color, icon) = switch (type) {
      MessageType.error => (
        CupertinoColors.systemRed,
        CupertinoIcons.exclamationmark_triangle,
      ),
      MessageType.success => (
        CupertinoColors.systemGreen,
        CupertinoIcons.checkmark_circle,
      ),
      MessageType.info => (
        CupertinoColors.systemBlue,
        CupertinoIcons.info_circle,
      ),
    };

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (onDismiss != null)
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: onDismiss,
              minimumSize: Size(0, 0),
              child: Icon(CupertinoIcons.xmark, color: color, size: 16),
            ),
        ],
      ),
    );
  }
}
