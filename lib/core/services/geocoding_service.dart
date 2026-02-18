// lib/core/services/geocoding_service.dart

import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config.dart';
import 'app_logger.dart';

/// Core geocoding service for reverse geocoding coordinates to city/state.
/// Extracted from MapSearchService to break core -> features dependency.
class GeocodingService {
  /// In-memory cache for reverse geocoding results (session lifetime).
  /// Key: "$lat,$lng" coordinate string. Coordinates never change for a given reach.
  static final Map<String, Map<String, String?>> _cache = {};

  /// Convert coordinates to city, state using Mapbox Geocoding API
  static Future<Map<String, String?>> reverseGeocode(
    double latitude,
    double longitude,
  ) async {
    final cacheKey = '$latitude,$longitude';

    if (_cache.containsKey(cacheKey)) {
      AppLogger.debug('GeocodingService', 'Cache hit for $cacheKey');
      return _cache[cacheKey]!;
    }

    try {
      AppLogger.debug('GeocodingService', 'Reverse geocoding $latitude, $longitude');

      final queryParams = {
        'access_token': AppConfig.mapboxPublicToken,
        'types': 'place,region',
      };

      final uri = Uri.parse(
        '${AppConfig.mapboxSearchApiUrl}$longitude,$latitude.json',
      ).replace(queryParameters: queryParams);

      final response = await http.get(uri).timeout(AppConfig.httpTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final features = data['features'] as List;

        if (features.isNotEmpty) {
          String? city, state;

          for (final feature in features) {
            final placeType = feature['place_type'] as List?;
            final text = feature['text'] as String?;
            final properties = feature['properties'] as Map?;

            if (placeType != null && text != null) {
              if (placeType.contains('place') && city == null) {
                city = text;
              } else if (placeType.contains('region') && state == null) {
                final shortCode = properties?['short_code'] as String?;
                if (shortCode != null && shortCode.contains('-')) {
                  state = shortCode.split('-').last.toUpperCase();
                } else {
                  state = text;
                }
              }
            }
          }

          AppLogger.debug('GeocodingService', 'Reverse geocoded to: $city, $state');
          final result = {'city': city, 'state': state};
          _cache[cacheKey] = result;
          return result;
        }
      } else {
        AppLogger.error('GeocodingService', 'API error ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      AppLogger.error('GeocodingService', 'Reverse geocoding failed', e);
    }

    final fallback = {'city': null, 'state': null};
    _cache[cacheKey] = fallback;
    return fallback;
  }
}
