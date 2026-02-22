// lib/features/forecast/widgets/flood_categories_info_sheet.dart

import 'package:flutter/cupertino.dart';
import '../../../core/constants.dart';
import 'package:get_it/get_it.dart';
import '../../../core/services/i_flow_unit_preference_service.dart';

/// Educational bottom sheet that explains flood risk categories based on return periods
class FloodCategoriesInfoSheet extends StatelessWidget {
  final Map<int, double>? returnPeriods;

  const FloodCategoriesInfoSheet({super.key, this.returnPeriods});

  // Get current flow unit display label from preference service
  String _getCurrentFlowUnit() {
    return GetIt.I<IFlowUnitPreferenceService>().getDisplayUnit();
  }

  // Convert return period value to user's preferred unit
  double? _convertReturnPeriod(double? cmsValue) {
    if (cmsValue == null) return null;

    final unitService = GetIt.I<IFlowUnitPreferenceService>();
    final currentUnit = unitService.currentFlowUnit;

    // Return periods are stored in CMS, convert to user preference
    return unitService.convertFlow(cmsValue, 'CMS', currentUnit);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        top: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Explanation
                    _buildExplanationSection(context),

                    const SizedBox(height: 20),

                    // Categories
                    _buildFloodCategoryItem(
                      context,
                      'Normal',
                      '0 - 2 year return period',
                      'Typical flow conditions with no flood risk',
                      AppConstants.returnPeriodNormalBg,
                      CupertinoColors.systemGrey,
                      CupertinoIcons.checkmark_circle_fill,
                      null,
                    ),

                    _buildFloodCategoryItem(
                      context,
                      'Action',
                      '2 - 5 year return period',
                      'Time to prepare - minor flooding possible',
                      AppConstants.returnPeriodActionBg,
                      CupertinoColors.systemYellow,
                      CupertinoIcons.exclamationmark_triangle,
                      _convertReturnPeriod(returnPeriods?[2]),
                    ),

                    _buildFloodCategoryItem(
                      context,
                      'Moderate',
                      '5 - 10 year return period',
                      'Some property damage and evacuations may be needed',
                      AppConstants.returnPeriodModerateBg,
                      CupertinoColors.systemOrange,
                      CupertinoIcons.exclamationmark_triangle_fill,
                      _convertReturnPeriod(returnPeriods?[5]),
                    ),

                    _buildFloodCategoryItem(
                      context,
                      'Major',
                      '10 - 25 year return period',
                      'Extensive property damage and life-threatening flooding',
                      AppConstants.returnPeriodMajorBg,
                      CupertinoColors.systemRed,
                      CupertinoIcons.exclamationmark_octagon_fill,
                      _convertReturnPeriod(returnPeriods?[10]),
                    ),

                    _buildFloodCategoryItem(
                      context,
                      'Extreme',
                      '25+ year return period',
                      'Catastrophic flooding with severe danger to life and property',
                      AppConstants.returnPeriodExtremeBg,
                      CupertinoColors.systemPurple,
                      CupertinoIcons.xmark_octagon_fill,
                      _convertReturnPeriod(returnPeriods?[25]),
                    ),

                    const SizedBox(height: 20),

                    // Note
                    _buildDisclaimerNote(context),

                    const SizedBox(height: 32), // Bottom padding for scrolling
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.systemGrey5.resolveFrom(context),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Flood Risk Categories',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label.resolveFrom(context),
              ),
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

  Widget _buildExplanationSection(BuildContext context) {
    return Text(
      'These categories help assess flood risk based on streamflow return periods. Return periods indicate how often flows of this magnitude typically occur.',
      style: TextStyle(
        fontSize: 14,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    );
  }

  Widget _buildFloodCategoryItem(
    BuildContext context,
    String title,
    String subtitle,
    String description,
    Color backgroundColor,
    Color iconColor,
    IconData icon,
    double? thresholdFlow,
  ) {
    // Get current flow unit for display
    final currentUnit = _getCurrentFlowUnit();

    // Calculate appropriate text colors based on background
    final textColor = _getTextColorForBackground(backgroundColor);
    final subtitleColor = _getSubtitleColorForBackground(backgroundColor);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: iconColor.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: iconColor,
                      ),
                    ),
                    if (thresholdFlow != null) ...[
                      const Spacer(),
                      Text(
                        '${_formatFlowValue(thresholdFlow)} $currentUnit',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: iconColor,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: subtitleColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(fontSize: 13, color: textColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper method to get appropriate text color for colored backgrounds
  Color _getTextColorForBackground(Color backgroundColor) {
    // Calculate luminance of the background color
    final luminance = backgroundColor.computeLuminance();

    // Use dark text for light backgrounds, light text for dark backgrounds
    if (luminance > 0.5) {
      return const Color(0xFF1D1D1F); // Dark gray text for light backgrounds
    } else {
      return const Color(0xFFFFFFFF); // White text for dark backgrounds
    }
  }

  // Helper method to get appropriate subtitle color for colored backgrounds
  Color _getSubtitleColorForBackground(Color backgroundColor) {
    // Calculate luminance of the background color
    final luminance = backgroundColor.computeLuminance();

    // Use slightly lighter/darker variants for subtitles
    if (luminance > 0.5) {
      return const Color(0xFF6D6D70); // Medium gray for light backgrounds
    } else {
      return const Color(0xFFE5E5E7); // Light gray for dark backgrounds
    }
  }

  Widget _buildDisclaimerNote(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Note: These categories are based on statistical analysis of historical flow data. Actual flood impacts may vary depending on local conditions, infrastructure, and other factors.',
        style: TextStyle(
          fontSize: 12,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
    );
  }

  String _formatFlowValue(double value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    } else if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    } else if (value >= 100) {
      return value.toStringAsFixed(0);
    } else {
      return value.toStringAsFixed(1);
    }
  }
}
