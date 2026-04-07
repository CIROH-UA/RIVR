// lib/ui/2_presentation/features/onboarding/pages/onboarding_page.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/ui/2_presentation/features/favorites/pages/favorites_page.dart';
import 'package:rivr/ui/2_presentation/features/onboarding/widgets/onboarding_page_content.dart';
import 'package:rivr/ui/2_presentation/features/onboarding/widgets/page_indicator.dart';
import 'package:rivr/services/4_infrastructure/onboarding/onboarding_service.dart';
import 'package:rivr/ui/2_presentation/features/auth/pages/auth_coordinator.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  static const _pages = [
    _PageData(
      imageAsset: 'assets/images/rivr_logo.png',
      title: 'Welcome to RIVR',
      subtitle: 'River Information Visualization and Risk',
      description:
          'River flow monitoring made simple. Access real-time data from '
          'the NOAA National Water Model to stay informed about the rivers '
          'that matter to you.',
      accentColor: CupertinoColors.systemBlue,
    ),
    _PageData(
      svgAsset: 'assets/images/onboarding/explore_rivers.svg',
      title: 'Explore Rivers',
      subtitle: 'Interactive map with 2.7 million river channels',
      description:
          'Navigate an interactive map powered by the National Water Model. '
          'Search any river in the United States and view current and '
          'future flow conditions at a glance.',
      accentColor: CupertinoColors.systemTeal,
    ),
    _PageData(
      svgAsset: 'assets/images/onboarding/forecasts_risk.svg',
      title: 'Forecasts & Flood Risk',
      subtitle: 'From 18 hours to 30 days ahead',
      description:
          'View short, medium, and long-range flow forecasts. Our '
          'color-coded risk system makes flood danger instantly clear.',
      accentColor: CupertinoColors.systemOrange,
    ),
    _PageData(
      svgAsset: 'assets/images/onboarding/save_monitor.svg',
      title: 'Save & Monitor',
      subtitle: 'Your rivers, your way',
      description:
          'Save your favorite rivers for quick access and receive push '
          'notifications when conditions change.',
      accentColor: CupertinoColors.systemPink,
    ),
  ];

  bool get _isLastPage => _currentPage == _pages.length - 1;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _completeOnboarding() async {
    await OnboardingService.completeOnboarding();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      CupertinoPageRoute(
        builder: (_) =>
            AuthCoordinator(onAuthSuccess: (context) => const FavoritesPage()),
      ),
    );
  }

  void _nextPage() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = _pages[_currentPage].accentColor;

    return CupertinoPageScaffold(
      child: SafeArea(
        child: Column(
          children: [
            // Skip button
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, top: 8),
                child: AnimatedOpacity(
                  opacity: _isLastPage ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: _isLastPage,
                    child: CupertinoButton(
                      onPressed: _completeOnboarding,
                      child: Text(
                        'Skip',
                        style: TextStyle(
                          color: CupertinoColors.systemGrey.resolveFrom(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Page content
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (index) {
                  setState(() => _currentPage = index);
                },
                itemBuilder: (context, index) {
                  final page = _pages[index];
                  return OnboardingPageContent(
                    svgAsset: page.svgAsset,
                    imageAsset: page.imageAsset,
                    title: page.title,
                    subtitle: page.subtitle,
                    description: page.description,
                    accentColor: page.accentColor,
                  );
                },
              ),
            ),

            // Page indicator
            PageIndicator(
              currentPage: _currentPage,
              pageCount: _pages.length,
              activeColor: accentColor,
            ),
            const SizedBox(height: 24),

            // Navigation button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoButton.filled(
                  onPressed: _isLastPage ? _completeOnboarding : _nextPage,
                  child: Text(_isLastPage ? 'Get Started' : 'Next'),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _PageData {
  const _PageData({
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
}
