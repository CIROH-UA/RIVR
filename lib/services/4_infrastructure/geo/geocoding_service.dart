// lib/services/4_infrastructure/geo/geocoding_service.dart

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:rivr/services/0_config/shared/config.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Core geocoding service for reverse geocoding coordinates to city/state.
/// Uses two-level caching: in-memory (L1) + SharedPreferences (L2).
class GeocodingService {
  /// L1: In-memory cache (session lifetime)
  static final Map<String, Map<String, String?>> _cache = {};

  static const _prefsPrefix = 'geocode_';

  /// Convert coordinates to city, state using Mapbox Geocoding API
  static Future<Map<String, String?>> reverseGeocode(
    double latitude,
    double longitude,
  ) async {
    final cacheKey = '$latitude,$longitude';

    // L1: Check in-memory cache
    if (_cache.containsKey(cacheKey)) {
      AppLogger.debug('GeocodingService', 'L1 cache hit for $cacheKey');
      return _cache[cacheKey]!;
    }

    // L2: Check SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final persisted = prefs.getString('$_prefsPrefix$cacheKey');
      if (persisted != null) {
        final decoded = Map<String, String?>.from(
          (jsonDecode(persisted) as Map).map(
            (k, v) => MapEntry(k.toString(), v as String?),
          ),
        );
        _cache[cacheKey] = decoded;
        AppLogger.debug('GeocodingService', 'L2 cache hit for $cacheKey');
        return decoded;
      }
    } catch (e) {
      AppLogger.warning('GeocodingService', 'L2 cache read failed: $e');
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

          // Persist to L2 (fire-and-forget)
          _persistResult(cacheKey, result);

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

  /// Persist a geocoding result to SharedPreferences (non-blocking)
  static Future<void> _persistResult(
    String cacheKey,
    Map<String, String?> result,
  ) async {
    try {
      // Only persist results that have actual data
      if (result['city'] == null && result['state'] == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefsPrefix$cacheKey', jsonEncode(result));
    } catch (e) {
      AppLogger.warning('GeocodingService', 'L2 cache write failed: $e');
    }
  }
}
