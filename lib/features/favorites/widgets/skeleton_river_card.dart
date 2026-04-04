// lib/features/favorites/widgets/skeleton_river_card.dart

import 'package:flutter/cupertino.dart';
import 'package:shimmer/shimmer.dart';

class SkeletonRiverCard extends StatelessWidget {
  const SkeletonRiverCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: CupertinoColors.systemGrey4.resolveFrom(context),
      highlightColor: CupertinoColors.systemGrey6.resolveFrom(context),
      child: Container(
        height: 120,
        margin: const EdgeInsets.symmetric(horizontal: 19, vertical: 6),
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey5.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Badge placeholder (top-left)
            Container(
              width: 80,
              height: 20,
              decoration: BoxDecoration(
                color: CupertinoColors.white,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const Spacer(),
            // River name placeholder
            Container(
              width: 160,
              height: 16,
              decoration: BoxDecoration(
                color: CupertinoColors.white,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 6),
            // Flow value placeholder
            Container(
              width: 100,
              height: 13,
              decoration: BoxDecoration(
                color: CupertinoColors.white,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
