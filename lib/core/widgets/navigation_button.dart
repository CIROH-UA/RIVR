// Custom Navigation Bar Components for RIVR
import 'package:flutter/cupertino.dart';

// ========================================
// 1. Basic Custom Navigation Bar Widget
// ========================================

class CustomNavBar extends StatelessWidget {
  final VoidCallback? onBackPressed;
  final Widget? rightWidget;
  final Color? backgroundColor;
  final Color? backButtonColor;
  final double? backButtonSize;
  final EdgeInsets? padding;

  const CustomNavBar({
    super.key,
    this.onBackPressed,
    this.rightWidget,
    this.backgroundColor,
    this.backButtonColor,
    this.backButtonSize,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Container(
        height: 44, // Standard navigation bar height
        color: backgroundColor ?? CupertinoColors.transparent,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Back button
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: onBackPressed ?? () => Navigator.of(context).pop(),
              child: Icon(
                CupertinoIcons.back,
                color: backButtonColor ?? CupertinoColors.systemBlue,
                size: backButtonSize ?? 24,
              ),
            ),

            // Right side widget (optional)
            rightWidget ?? const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

// ========================================
// 2. Floating Back Button (Minimal Approach)
// ========================================

class FloatingBackButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Color? backgroundColor;
  final Color? iconColor;
  final double? size;
  final EdgeInsets? margin;
  final bool showBackground;

  const FloatingBackButton({
    super.key,
    this.onPressed,
    this.backgroundColor,
    this.iconColor,
    this.size,
    this.margin,
    this.showBackground = true,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: margin ?? const EdgeInsets.only(top: 8, left: 16),
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: onPressed ?? () => Navigator.of(context).pop(),
          child: Container(
            width: size ?? 45,
            height: size ?? 45,
            decoration: showBackground
                ? BoxDecoration(
                    color:
                        backgroundColor ??
                        CupertinoColors.white.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular((size ?? 40) / 2),
                    boxShadow: [
                      BoxShadow(
                        color: CupertinoColors.black.withValues(alpha: 0.1),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  )
                : null,
            child: Icon(
              CupertinoIcons.back,
              color: iconColor ?? CupertinoColors.systemBlue,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
