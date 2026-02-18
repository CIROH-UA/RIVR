// lib/features/map/widgets/components/return_periods_info_sheet.dart

import 'package:flutter/cupertino.dart';

/// Educational bottom sheet that explains return periods and flood risk thresholds
class ReturnPeriodsInfoSheet extends StatelessWidget {
  final Map<int, double> returnPeriods;

  const ReturnPeriodsInfoSheet({super.key, required this.returnPeriods});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: CupertinoColors.systemBackground,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Explanation section
                    _buildExplanationSection(),

                    const SizedBox(height: 24),

                    // Current usage section
                    _buildCurrentUsageSection(),

                    const SizedBox(height: 24),

                    // Risk thresholds table
                    _buildRiskThresholdsTable(returnPeriods),

                    // Add some bottom padding for better scrolling
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: CupertinoColors.systemGrey5, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Flood Risk Thresholds',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.of(context).pop(),
            child: const Icon(
              CupertinoIcons.xmark_circle_fill,
              color: CupertinoColors.systemGrey3,
              size: 24,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExplanationSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'What are Return Periods?',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.label,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'A "return period" tells you how rare a flood is. A 10-year flood has a 10% chance of happening in any given year. The higher the number, the more dangerous the flood.',
          style: TextStyle(fontSize: 14, color: CupertinoColors.label),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CupertinoColors.systemGreen.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(
                CupertinoIcons.lightbulb,
                color: CupertinoColors.systemGreen,
                size: 16,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Think of it like this: A 100-year flood is much more dangerous than a 2-year flood.',
                  style: TextStyle(
                    fontSize: 12,
                    color: CupertinoColors.systemGreen,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCurrentUsageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'How We Use This Data',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.label,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'RIVR compares current river flow to these thresholds to show you the flood risk level:',
          style: TextStyle(fontSize: 14, color: CupertinoColors.label),
        ),
        const SizedBox(height: 12),

        // Risk level indicators
        _buildRiskLevelIndicator(
          'Normal',
          'Below 2-year level',
          CupertinoColors.systemGreen,
          CupertinoIcons.checkmark_circle_fill,
        ),
        _buildRiskLevelIndicator(
          'Elevated',
          'Between 2-5 year levels',
          CupertinoColors.systemYellow,
          CupertinoIcons.arrow_up_circle,
        ),
        _buildRiskLevelIndicator(
          'High',
          'Between 5-25 year levels',
          CupertinoColors.systemOrange,
          CupertinoIcons.arrow_up_circle_fill,
        ),
        _buildRiskLevelIndicator(
          'Flood Risk',
          'Above 25-year level',
          CupertinoColors.systemRed,
          CupertinoIcons.exclamationmark_triangle_fill,
        ),
      ],
    );
  }

  Widget _buildRiskLevelIndicator(
    String level,
    String description,
    Color color,
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 14,
                  color: CupertinoColors.label,
                ),
                children: [
                  TextSpan(
                    text: '$level: ',
                    style: TextStyle(fontWeight: FontWeight.w600, color: color),
                  ),
                  TextSpan(text: description),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRiskThresholdsTable(Map<int, double> returnPeriods) {
    // Sort return periods by year and convert cms to cfs
    const cmsToCs = 35.3147; // 1 cms = 35.3147 cubic feet per second
    final sortedPeriods = returnPeriods.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Risk Thresholds for This Location',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.label,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: CupertinoColors.systemGrey4),
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 16,
                ),
                decoration: const BoxDecoration(
                  color: CupertinoColors.systemGrey6,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(7),
                    topRight: Radius.circular(7),
                  ),
                ),
                child: const Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(
                        'Return Period',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.secondaryLabel,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        'Flow (ft³/s)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.secondaryLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Data rows
              ...sortedPeriods.asMap().entries.map((entry) {
                final index = entry.key;
                final period = entry.value;
                final isLast = index == sortedPeriods.length - 1;
                final flowInCfs = period.value * cmsToCs; // Convert cms to cfs

                return Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 16,
                  ),
                  decoration: BoxDecoration(
                    border: isLast
                        ? null
                        : const Border(
                            bottom: BorderSide(
                              color: CupertinoColors.systemGrey5,
                            ),
                          ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          '${period.key}-year',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          flowInCfs.toStringAsFixed(0),
                          style: const TextStyle(
                            fontSize: 14,
                            color: CupertinoColors.secondaryLabel,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),

        const SizedBox(height: 12),
        const Text(
          'Current flow is compared to these values to determine flood risk.',
          style: TextStyle(
            fontSize: 12,
            color: CupertinoColors.systemGrey,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }
}
