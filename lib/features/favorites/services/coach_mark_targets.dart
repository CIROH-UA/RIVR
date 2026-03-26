// lib/features/favorites/services/coach_mark_targets.dart

import 'package:flutter/cupertino.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';

class CoachMarkTargets {
  /// Phase A targets: pull-to-refresh, swipe left, settings menu
  static List<TargetFocus> buildFavoritesTourTargets({
    required GlobalKey firstCardKey,
    required GlobalKey settingsButtonKey,
  }) {
    const totalSteps = 3;

    return [
      TargetFocus(
        identify: 'pull_to_refresh',
        keyTarget: firstCardKey,
        alignSkip: Alignment.bottomCenter,
        enableOverlayTab: false,
        enableTargetTab: false,
        shape: ShapeLightFocus.RRect,
        radius: 12,
        contents: [
          TargetContent(
            align: ContentAlign.bottom,
            builder: (context, controller) => _buildTipContent(
              icon: CupertinoIcons.arrow_down,
              title: 'Pull to Refresh',
              description:
                  'Pull down on the list to refresh flow data for all your rivers.',
              step: 1,
              totalSteps: totalSteps,
              onNext: controller.next,
            ),
          ),
        ],
      ),
      TargetFocus(
        identify: 'swipe_left',
        keyTarget: firstCardKey,
        alignSkip: Alignment.bottomCenter,
        enableOverlayTab: false,
        enableTargetTab: false,
        shape: ShapeLightFocus.RRect,
        radius: 12,
        contents: [
          TargetContent(
            align: ContentAlign.bottom,
            builder: (context, controller) => _buildTipContent(
              icon: CupertinoIcons.arrow_left,
              title: 'Swipe for Actions',
              description:
                  'Swipe left on a card to rename, change its image, or remove it.',
              step: 2,
              totalSteps: totalSteps,
              onNext: controller.next,
            ),
          ),
        ],
      ),
      TargetFocus(
        identify: 'settings_menu',
        keyTarget: settingsButtonKey,
        alignSkip: Alignment.bottomCenter,
        enableOverlayTab: false,
        enableTargetTab: false,
        shape: ShapeLightFocus.Circle,
        contents: [
          TargetContent(
            align: ContentAlign.bottom,
            builder: (context, controller) => _buildTipContent(
              icon: CupertinoIcons.ellipsis,
              title: 'Settings & More',
              description:
                  'Tap here to manage notifications, change flow units, switch themes, and more.',
              step: 3,
              totalSteps: totalSteps,
              onNext: controller.next,
            ),
          ),
        ],
      ),
    ];
  }

  /// Phase B target: search icon
  static List<TargetFocus> buildSearchTipTargets({
    required GlobalKey searchIconKey,
  }) {
    return [
      TargetFocus(
        identify: 'search_icon',
        keyTarget: searchIconKey,
        alignSkip: Alignment.bottomCenter,
        enableOverlayTab: false,
        enableTargetTab: false,
        shape: ShapeLightFocus.Circle,
        contents: [
          TargetContent(
            align: ContentAlign.bottom,
            builder: (context, controller) => _buildTipContent(
              icon: CupertinoIcons.search,
              title: 'Search Your Rivers',
              description:
                  'Quickly find a river in your favorites list.',
              step: 1,
              totalSteps: 1,
              onNext: controller.next,
            ),
          ),
        ],
      ),
    ];
  }

  static Widget _buildTipContent({
    required IconData icon,
    required String title,
    required String description,
    required int step,
    required int totalSteps,
    required VoidCallback onNext,
  }) {
    final isLast = step == totalSteps;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step indicator
          if (totalSteps > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '$step of $totalSteps',
                style: const TextStyle(
                  color: CupertinoColors.systemGrey,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
            ),

          // Icon + title
          Row(
            children: [
              Icon(icon, color: CupertinoColors.white, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Description
          Text(
            description,
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 16,
              fontWeight: FontWeight.w400,
              height: 1.4,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 16),

          // Next / Got it button
          Align(
            alignment: Alignment.centerRight,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              color: CupertinoColors.systemBlue,
              borderRadius: BorderRadius.circular(20),
              onPressed: onNext,
              child: Text(
                isLast ? 'Got it' : 'Next',
                style: const TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
