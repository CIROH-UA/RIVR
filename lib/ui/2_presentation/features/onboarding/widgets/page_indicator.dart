// lib/ui/2_presentation/features/onboarding/widgets/page_indicator.dart

import 'package:flutter/cupertino.dart';

class PageIndicator extends StatelessWidget {
  const PageIndicator({
    super.key,
    required this.currentPage,
    required this.pageCount,
    required this.activeColor,
  });

  final int currentPage;
  final int pageCount;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(pageCount, (index) {
        final isActive = index == currentPage;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 24 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: isActive
                ? activeColor
                : CupertinoColors.systemGrey3.resolveFrom(context),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}
