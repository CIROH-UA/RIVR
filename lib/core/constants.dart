// lib/core/constants.dart
//
// App-wide constants and helper methods that are not sensitive information
// like API keys and URLs. For sensitive configuration, see config.dart.
//

import 'package:flutter/cupertino.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'providers/theme_provider.dart';
import 'services/map_preference_service.dart';

/// Forecast information for display
class ForecastInfo {
  final String name;
  final String purpose;
  final String duration;
  final String frequency;
  final String type;
  final String useCase;
  final List<String> sourceUrls; // Support multiple URLs

  const ForecastInfo({
    required this.name,
    required this.purpose,
    required this.duration,
    required this.frequency,
    required this.type,
    required this.useCase,
    required this.sourceUrls,
  });
}

/// Simple data class for Syncfusion charts
class ChartData {
  final double x;
  final double y;

  const ChartData(this.x, this.y);
}

class AppConstants {
  AppConstants._(); // Private constructor to prevent instantiation

  // MARK: - Map Style Configuration

  /// Default map style URL for initial load (before preferences are loaded)
  static const String defaultMapboxStyleUrl =
      'mapbox://styles/mapbox/streets-v12';

  /// Get active map style URL based on user preferences and theme
  /// This is the main method the map should use
  static Future<String> getActiveMapStyleUrl(
    ThemeProvider themeProvider,
  ) async {
    final activeLayer = await MapPreferenceService.getActiveMapLayer(
      themeProvider,
    );
    return activeLayer.styleUrl;
  }

  /// Get map style URL for a specific brightness (for auto mode)
  static String getAutoMapStyleUrl(Brightness brightness) {
    final layer = MapPreferenceService.getAutoMapLayerForBrightness(brightness);
    return layer.styleUrl;
  }

  // MARK: - Return Period Chart Colors

  /// Background colors for return period zones
  static const Color returnPeriodNormalBg = Color(0xFFFFFFFF); // White (0-2yr)
  static const Color returnPeriodActionBg = Color(
    0xFFFFF9C4,
  ); // Subtle Yellow (2-5yr)
  static const Color returnPeriodModerateBg = Color(
    0xFFFFE0B2,
  ); // Subtle Orange (5-10yr)
  static const Color returnPeriodMajorBg = Color(
    0xFFFFCDD2,
  ); // Subtle Red (10-25yr)
  static const Color returnPeriodExtremeBg = Color(
    0xFFE1BEE7,
  ); // Subtle Purple (25yr+)

  /// Get display label for return period lines
  static String getReturnPeriodLabel(int years) {
    switch (years) {
      case 5:
        return 'Action';
      case 10:
        return 'Moderate';
      case 25:
        return 'Major';
      default:
        return '${years}yr';
    }
  }

  /// Create PlotBand for flood zones
  static PlotBand createFloodZonePlotBand(
    double start,
    double end,
    String zoneName,
  ) {
    Color backgroundColor;
    switch (zoneName.toLowerCase()) {
      case 'normal':
        backgroundColor = returnPeriodNormalBg;
        break;
      case 'action':
        backgroundColor = returnPeriodActionBg;
        break;
      case 'moderate':
        backgroundColor = returnPeriodModerateBg;
        break;
      case 'major':
        backgroundColor = returnPeriodMajorBg;
        break;
      case 'extreme':
        backgroundColor = returnPeriodExtremeBg;
        break;
      default:
        backgroundColor = returnPeriodNormalBg;
    }

    return PlotBand(
      start: start,
      end: end,
      color: backgroundColor,
      opacity: 0.8,
    );
  }

  // MARK: - Stream Order Styling

  /// Get stream order color for consistent styling
  static Color getStreamOrderColor(int streamOrder) {
    if (streamOrder >= 8) return CupertinoColors.systemIndigo;
    if (streamOrder >= 5) return CupertinoColors.systemBlue;
    if (streamOrder >= 3) return CupertinoColors.systemTeal;
    return CupertinoColors.systemGreen;
  }

  /// Get stream order icon for consistent iconography
  static IconData getStreamOrderIcon(int streamOrder) {
    // Always return water drop icon regardless of stream order
    return CupertinoIcons.drop_fill;
  }

  // MARK: - Flow Category Styling

  /// Get flow category color for consistent styling
  static Color getFlowCategoryColor(String? flowCategory) {
    switch (flowCategory?.toLowerCase()) {
      case 'extreme':
        return CupertinoColors
            .systemPurple; // Matches returnPeriodExtremeBg theme
      case 'major':
        return CupertinoColors.systemRed; // Matches returnPeriodMajorBg theme
      case 'moderate':
        return CupertinoColors
            .systemOrange; // Matches returnPeriodModerateBg theme
      case 'action':
        return CupertinoColors
            .systemYellow; // Matches returnPeriodActionBg theme
      case 'normal':
        return CupertinoColors.systemBlue; // Safe/normal condition
      default:
        return CupertinoColors.systemGrey;
    }
  }

  /// Get flow category icon for consistent iconography
  static IconData getFlowCategoryIcon(String? flowCategory) {
    switch (flowCategory?.toLowerCase()) {
      case 'extreme':
        return CupertinoIcons.xmark_octagon_fill; // Highest danger level
      case 'major':
        return CupertinoIcons.exclamationmark_triangle_fill; // High danger
      case 'moderate':
        return CupertinoIcons.exclamationmark_triangle; // Medium danger
      case 'action':
        return CupertinoIcons.info_circle_fill; // Action required
      case 'normal':
        return CupertinoIcons.checkmark_circle_fill; // Safe condition
      default:
        return CupertinoIcons.question_circle;
    }
  }

  // MARK: - NOAA Forecast Definitions

  /// Static forecast definitions - never change
  static const Map<String, ForecastInfo> forecastDefinitions = {
    'analysis_assimilation': ForecastInfo(
      name: 'Analysis & Assimilation',
      purpose: 'Real-time analysis of current streamflow and hydrologic states',
      duration: 'Current conditions (hourly snapshots)',
      frequency: 'Updated hourly',
      type: 'Real-time data with USGS gauge assimilation',
      useCase: 'Establishes initial conditions for all other forecasts',
      sourceUrls: ['https://water.noaa.gov/about/nwm'],
    ),
    'short_range': ForecastInfo(
      name: 'Short Range',
      purpose: 'Flash flood and emergency response',
      duration: '18 hours',
      frequency: 'Updated hourly',
      type: 'Deterministic (single value)',
      useCase:
          'Emergency responders, forecasters dealing with rapidly evolving conditions',
      sourceUrls: [
        'https://registry.opendata.aws/noaa-nwm-pds/',
        'https://onlinelibrary.wiley.com/doi/10.1111/1752-1688.13184',
      ],
    ),
    'medium_range': ForecastInfo(
      name: 'Medium Range',
      purpose: 'Water resource management and planning',
      duration: '10 days',
      frequency: 'Updated 4 times per day (every 6 hours)',
      type: 'Ensemble forecast (multiple members)',
      useCase: 'Reservoir operators, water managers, agricultural planning',
      sourceUrls: [
        'https://onlinelibrary.wiley.com/doi/10.1111/1752-1688.13184',
        'https://water.noaa.gov/about/nwm',
      ],
    ),
    'long_range': ForecastInfo(
      name: 'Long Range',
      purpose: 'Seasonal planning and drought/flood outlook',
      duration: '30 days',
      frequency: 'Updated 4 times per day (every 6 hours)',
      type: '4-member ensemble forecast',
      useCase: 'Long-term water resource planning, drought monitoring',
      sourceUrls: [
        'https://onlinelibrary.wiley.com/doi/10.1111/1752-1688.13184',
        'https://water.noaa.gov/about/nwm',
      ],
    ),
    'medium_range_blend': ForecastInfo(
      name: 'Medium Range Blend',
      purpose: 'Enhanced 10-day forecast using advanced weather blending',
      duration: '10 days',
      frequency: 'Updated 4 times per day (every 6 hours)',
      type: 'Deterministic (single value)',
      useCase:
          'Improved medium-range accuracy by combining multiple weather prediction models',
      sourceUrls: [
        'https://www.weather.gov/news/200318-nbm32',
        'https://water.noaa.gov/about/nwm',
        'https://vlab.noaa.gov/web/mdl/nbm',
      ],
    ),
  };

  /// Get forecast information by type
  static ForecastInfo? getForecastInfo(String forecastType) {
    return forecastDefinitions[forecastType];
  }

  /// Get forecasts in preferred display order
  static List<String> getOrderedForecasts(List<String> availableForecasts) {
    // Define preferred order for display
    const preferredOrder = [
      'analysis_assimilation',
      'short_range',
      'medium_range',
      'medium_range_blend',
      'long_range',
    ];

    final result = <String>[];

    // Add forecasts in preferred order
    for (final forecast in preferredOrder) {
      if (availableForecasts.contains(forecast)) {
        result.add(forecast);
      }
    }

    // Add any remaining forecasts not in preferred order
    for (final forecast in availableForecasts) {
      if (!result.contains(forecast)) {
        result.add(forecast);
      }
    }

    return result;
  }

  /// Get forecast color for consistent styling
  static Color getForecastColor(String forecastType) {
    switch (forecastType) {
      case 'analysis_assimilation':
        return CupertinoColors.systemGreen;
      case 'short_range':
        return CupertinoColors.systemBlue;
      case 'medium_range':
        return CupertinoColors.systemOrange;
      case 'medium_range_blend':
        return CupertinoColors.systemPurple;
      case 'long_range':
        return CupertinoColors.systemRed;
      default:
        return CupertinoColors.systemGrey;
    }
  }
}
