// lib/features/onboarding/widgets/onboarding_page_content.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';

class OnboardingPageContent extends StatelessWidget {
  const OnboardingPageContent({
    super.key,
    this.svgAsset,
    this.imageAsset,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.accentColor,
  }) : assert(svgAsset != null || imageAsset != null);

  final String? svgAsset;
  final String? imageAsset;
  final String title;
  final String subtitle;
  final String description;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final textColor = CupertinoColors.black;
    final secondaryTextColor = CupertinoColors.systemGrey;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(flex: 2),
          if (svgAsset != null)
            SvgPicture.asset(
              svgAsset!,
              width: 200,
              height: 200,
            )
          else
            Image.asset(
              imageAsset!,
              width: 200,
              height: 200,
            ),
          const Spacer(),
          Text(
            title,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: accentColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            description,
            style: TextStyle(
              fontSize: 16,
              color: secondaryTextColor,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const Spacer(flex: 3),
        ],
      ),
    );
  }
}
