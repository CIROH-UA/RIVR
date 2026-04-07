// lib/services/3_datasources/shared/dtos/reach_data_dto.dart

import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/models/1_domain/shared/reach_data.dart';

/// Data Transfer Object for [ReachData].
///
/// Handles JSON serialization (cache), NOAA API parsing, and return-period
/// API parsing. The pure [ReachData] entity contains only domain logic.
class ReachDataDto {
  final String reachId;
  final String riverName;
  final double latitude;
  final double longitude;
  final String? city;
  final String? state;
  final List<String> availableForecasts;
  final Map<int, double>? returnPeriods;
  final List<String>? upstreamReaches;
  final List<String>? downstreamReaches;
  final String? customName;
  final String cachedAt;
  final String? lastApiUpdate;
  final bool isPartiallyLoaded;

  const ReachDataDto({
    required this.reachId,
    required this.riverName,
    required this.latitude,
    required this.longitude,
    this.city,
    this.state,
    required this.availableForecasts,
    this.returnPeriods,
    this.upstreamReaches,
    this.downstreamReaches,
    this.customName,
    required this.cachedAt,
    this.lastApiUpdate,
    this.isPartiallyLoaded = false,
  });

  // ── NOAA Reaches API parser ────────────────────────────────────────────────

  factory ReachDataDto.fromNoaaApi(Map<String, dynamic> json) {
    try {
      final route = json['route'] as Map<String, dynamic>?;

      return ReachDataDto(
        reachId: (json['reachId'] as String).trim(),
        riverName: json['name'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        availableForecasts: (json['streamflow'] as List<dynamic>)
            .map((e) => e.toString())
            .toList(),
        upstreamReaches: route?['upstream'] != null
            ? (route!['upstream'] as List<dynamic>)
                  .map((e) => (e as Map<String, dynamic>)['reachId'] as String)
                  .toList()
            : null,
        downstreamReaches: route?['downstream'] != null
            ? (route!['downstream'] as List<dynamic>)
                  .map((e) => (e as Map<String, dynamic>)['reachId'] as String)
                  .toList()
            : null,
        cachedAt: DateTime.now().toIso8601String(),
        isPartiallyLoaded: false,
      );
    } catch (e) {
      throw FormatException('Failed to parse NOAA reaches API response: $e');
    }
  }

  // ── Return Period API parser ───────────────────────────────────────────────

  factory ReachDataDto.fromReturnPeriodApi(List<dynamic> jsonArray) {
    try {
      if (jsonArray.isEmpty) {
        throw FormatException('Return period API returned empty array');
      }

      final json = jsonArray.first as Map<String, dynamic>;
      final featureId = json['feature_id'].toString();

      final returnPeriods = <int, double>{};
      for (final entry in json.entries) {
        if (entry.key.startsWith('return_period_')) {
          final years = int.tryParse(
            entry.key.substring('return_period_'.length),
          );
          final flow = (entry.value as num).toDouble();
          if (years != null) {
            returnPeriods[years] = flow;
          }
        }
      }

      return ReachDataDto(
        reachId: featureId,
        riverName: 'Unknown',
        latitude: 0.0,
        longitude: 0.0,
        availableForecasts: [],
        returnPeriods: returnPeriods,
        cachedAt: DateTime.now().toIso8601String(),
        isPartiallyLoaded: true,
      );
    } catch (e) {
      throw FormatException('Failed to parse return period API response: $e');
    }
  }

  // ── Cache JSON serialization ───────────────────────────────────────────────

  factory ReachDataDto.fromJson(Map<String, dynamic> json) {
    return ReachDataDto(
      reachId: json['reachId'] as String,
      riverName: json['riverName'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      city: json['city'] as String?,
      state: json['state'] as String?,
      availableForecasts: (json['availableForecasts'] as List<dynamic>)
          .map((e) => e.toString())
          .toList(),
      returnPeriods: json['returnPeriods'] != null
          ? Map<int, double>.from(
              (json['returnPeriods'] as Map<String, dynamic>).map(
                (key, value) =>
                    MapEntry(int.parse(key), (value as num).toDouble()),
              ),
            )
          : null,
      upstreamReaches: json['upstreamReaches'] != null
          ? (json['upstreamReaches'] as List<dynamic>)
                .map((e) => e.toString())
                .toList()
          : null,
      downstreamReaches: json['downstreamReaches'] != null
          ? (json['downstreamReaches'] as List<dynamic>)
                .map((e) => e.toString())
                .toList()
          : null,
      customName: json['customName'] as String?,
      cachedAt: json['cachedAt'] as String,
      lastApiUpdate: json['lastApiUpdate'] as String?,
      isPartiallyLoaded: json['isPartiallyLoaded'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'reachId': reachId,
      'riverName': riverName,
      'latitude': latitude,
      'longitude': longitude,
      'city': city,
      'state': state,
      'availableForecasts': availableForecasts,
      'returnPeriods': returnPeriods?.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
      'upstreamReaches': upstreamReaches,
      'downstreamReaches': downstreamReaches,
      'customName': customName,
      'cachedAt': cachedAt,
      'lastApiUpdate': lastApiUpdate,
      'isPartiallyLoaded': isPartiallyLoaded,
    };
  }

  // ── Entity conversion ─────────────────────────────────────────────────────

  ReachData toEntity() {
    return ReachData(
      reachId: reachId,
      riverName: riverName,
      latitude: latitude,
      longitude: longitude,
      city: city,
      state: state,
      availableForecasts: availableForecasts,
      returnPeriods: returnPeriods,
      upstreamReaches: upstreamReaches,
      downstreamReaches: downstreamReaches,
      customName: customName,
      cachedAt: DateTime.parse(cachedAt),
      lastApiUpdate:
          lastApiUpdate != null ? DateTime.parse(lastApiUpdate!) : null,
      isPartiallyLoaded: isPartiallyLoaded,
    );
  }

  static ReachDataDto fromEntity(ReachData entity) {
    return ReachDataDto(
      reachId: entity.reachId,
      riverName: entity.riverName,
      latitude: entity.latitude,
      longitude: entity.longitude,
      city: entity.city,
      state: entity.state,
      availableForecasts: entity.availableForecasts,
      returnPeriods: entity.returnPeriods,
      upstreamReaches: entity.upstreamReaches,
      downstreamReaches: entity.downstreamReaches,
      customName: entity.customName,
      cachedAt: entity.cachedAt.toIso8601String(),
      lastApiUpdate: entity.lastApiUpdate?.toIso8601String(),
      isPartiallyLoaded: entity.isPartiallyLoaded,
    );
  }
}

/// Data Transfer Object for [ForecastPoint].
class ForecastPointDto {
  final String validTime;
  final double flow;

  const ForecastPointDto({required this.validTime, required this.flow});

  factory ForecastPointDto.fromJson(Map<String, dynamic> json) {
    return ForecastPointDto(
      validTime: json['validTime'] as String,
      flow: (json['flow'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'validTime': validTime, 'flow': flow};
  }

  ForecastPoint toEntity() {
    return ForecastPoint(
      validTime: DateTime.parse(validTime),
      flow: flow,
    );
  }

  static ForecastPointDto fromEntity(ForecastPoint entity) {
    return ForecastPointDto(
      validTime: entity.validTime.toIso8601String(),
      flow: entity.flow,
    );
  }
}

/// Data Transfer Object for [ForecastSeries].
class ForecastSeriesDto {
  final String? referenceTime;
  final String units;
  final List<ForecastPointDto> data;

  const ForecastSeriesDto({
    this.referenceTime,
    required this.units,
    required this.data,
  });

  factory ForecastSeriesDto.fromJson(Map<String, dynamic> json) {
    return ForecastSeriesDto(
      referenceTime: json['referenceTime'] as String?,
      units: json['units'] as String? ?? '',
      data: json['data'] != null
          ? (json['data'] as List<dynamic>)
                .map((e) =>
                    ForecastPointDto.fromJson(e as Map<String, dynamic>))
                .toList()
          : [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'referenceTime': referenceTime,
      'units': units,
      'data': data.map((e) => e.toJson()).toList(),
    };
  }

  ForecastSeries toEntity() {
    return ForecastSeries(
      referenceTime:
          referenceTime != null ? DateTime.parse(referenceTime!) : null,
      units: units,
      data: data.map((e) => e.toEntity()).toList(),
    );
  }

  static ForecastSeriesDto fromEntity(ForecastSeries entity) {
    return ForecastSeriesDto(
      referenceTime: entity.referenceTime?.toIso8601String(),
      units: entity.units,
      data: entity.data.map((e) => ForecastPointDto.fromEntity(e)).toList(),
    );
  }
}

/// Data Transfer Object / parser for [ForecastResponse].
///
/// Contains all the complex NOAA API response parsing logic that was
/// previously in [ForecastResponse.fromJson].
class ForecastResponseDto {
  ForecastResponseDto._();

  /// Parse a NOAA API response into a [ForecastResponse] entity.
  static ForecastResponse fromApiResponse(Map<String, dynamic> json) {
    return ForecastResponse(
      reach: ReachDataDto.fromNoaaApi(
        json['reach'] as Map<String, dynamic>,
      ).toEntity(),
      analysisAssimilation: _parseForecastSection(
        json['analysisAssimilation'],
        'analysis_assimilation',
      ),
      shortRange: _parseForecastSection(json['shortRange'], 'short_range'),
      mediumRange: _parseEnsembleForecast(json['mediumRange'], 'medium_range'),
      longRange: _parseEnsembleForecast(json['longRange'], 'long_range'),
      mediumRangeBlend: _parseForecastSection(
        json['mediumRangeBlend'],
        'medium_range_blend',
      ),
    );
  }

  // ── Parsing helpers ─────────────────────────────────────────────────────────

  static ForecastSeries? _parseForecastSection(
    dynamic section,
    String forecastType,
  ) {
    if (section == null || section is! Map<String, dynamic>) {
      AppLogger.debug('ReachDataDto', 'ForecastParser: No data for $forecastType');
      return null;
    }

    // Try 'series' data first (used by short_range)
    final series = section['series'];
    if (series != null && series is Map<String, dynamic>) {
      try {
        final forecastSeries =
            ForecastSeriesDto.fromJson(series).toEntity();
        if (forecastSeries.isNotEmpty) {
          AppLogger.debug(
            'ReachDataDto',
            'ForecastParser: Using series data for $forecastType (${forecastSeries.data.length} points)',
          );
          return forecastSeries;
        }
      } catch (e) {
        AppLogger.error(
          'ReachDataDto',
          'ForecastParser: Series data invalid for $forecastType',
          e,
        );
      }
    }

    // Try 'mean' data (used by medium_range/long_range sometimes)
    final mean = section['mean'];
    if (mean != null && mean is Map<String, dynamic>) {
      try {
        final forecastSeries =
            ForecastSeriesDto.fromJson(mean).toEntity();
        if (forecastSeries.isNotEmpty) {
          AppLogger.debug(
            'ReachDataDto',
            'ForecastParser: Using mean data for $forecastType (${forecastSeries.data.length} points)',
          );
          return forecastSeries;
        }
      } catch (e) {
        AppLogger.error(
          'ReachDataDto',
          'ForecastParser: Mean data invalid for $forecastType',
          e,
        );
      }
    }

    // Fall back to ensemble members dynamically
    final memberKeys = section.keys
        .where((key) => key.startsWith('member'))
        .toList();
    memberKeys.sort();

    for (final memberKey in memberKeys) {
      final memberData = section[memberKey];
      if (memberData != null && memberData is Map<String, dynamic>) {
        try {
          final memberSeries =
              ForecastSeriesDto.fromJson(memberData).toEntity();
          if (memberSeries.isNotEmpty) {
            AppLogger.debug(
              'ReachDataDto',
              'ForecastParser: Using $memberKey data for $forecastType (${memberSeries.data.length} points)',
            );
            return memberSeries;
          }
        } catch (e) {
          AppLogger.error(
            'ReachDataDto',
            'ForecastParser: $memberKey data invalid for $forecastType',
            e,
          );
          continue;
        }
      }
    }

    AppLogger.debug(
      'ReachDataDto',
      'ForecastParser: No valid data found for $forecastType (tried series, mean, and ${memberKeys.length} members)',
    );
    return null;
  }

  static Map<String, ForecastSeries> _parseEnsembleForecast(
    dynamic section,
    String forecastType,
  ) {
    if (section == null || section is! Map<String, dynamic>) {
      AppLogger.debug(
        'ReachDataDto',
        'ForecastParser: No ensemble data for $forecastType',
      );
      return {};
    }

    final result = <String, ForecastSeries>{};

    // Try to get 'series' data and store as 'mean'
    final seriesData = section['series'];
    if (seriesData != null && seriesData is Map<String, dynamic>) {
      try {
        final series = ForecastSeriesDto.fromJson(seriesData).toEntity();
        if (series.isNotEmpty) {
          result['mean'] = series;
          AppLogger.debug(
            'ReachDataDto',
            'ForecastParser: Found series data for $forecastType as mean (${series.data.length} points)',
          );
        }
      } catch (e) {
        AppLogger.error(
          'ReachDataDto',
          'ForecastParser: Series data invalid for $forecastType',
          e,
        );
      }
    }

    // Try to get explicit 'mean' data (overrides series if both exist)
    final meanData = section['mean'];
    if (meanData != null && meanData is Map<String, dynamic>) {
      try {
        final mean = ForecastSeriesDto.fromJson(meanData).toEntity();
        if (mean.isNotEmpty) {
          result['mean'] = mean;
          AppLogger.debug(
            'ReachDataDto',
            'ForecastParser: Found explicit mean data for $forecastType (${mean.data.length} points)',
          );
        }
      } catch (e) {
        AppLogger.error(
          'ReachDataDto',
          'ForecastParser: Mean data invalid for $forecastType',
          e,
        );
      }
    }

    // Collect ALL ensemble members dynamically
    final memberKeys = section.keys
        .where((key) => key.startsWith('member'))
        .toList();
    memberKeys.sort();

    for (final memberKey in memberKeys) {
      final memberData = section[memberKey];
      if (memberData != null && memberData is Map<String, dynamic>) {
        try {
          final memberSeries =
              ForecastSeriesDto.fromJson(memberData).toEntity();
          if (memberSeries.isNotEmpty) {
            result[memberKey] = memberSeries;
          }
        } catch (_) {
          continue;
        }
      }
    }

    final validMemberCount = result.keys
        .where((k) => k.startsWith('member'))
        .length;

    AppLogger.debug(
      'ReachDataDto',
      'ForecastParser: Found ${result.length} valid series for $forecastType: ${result.keys.join(", ")} ($validMemberCount/${memberKeys.length} members valid)',
    );

    return result;
  }
}
