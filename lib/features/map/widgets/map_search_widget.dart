// lib/features/map/widgets/map_search_widget.dart

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import '../../../core/config.dart';
import '../../../core/services/cache_service.dart';

/// Simplified place search for Rivrflow using existing patterns
class SearchedPlace {
  final String placeName;
  final String shortName;
  final double longitude;
  final double latitude;
  final String? category;
  final String? address;
  final List<String> context;

  const SearchedPlace({
    required this.placeName,
    required this.shortName,
    required this.longitude,
    required this.latitude,
    this.category,
    this.address,
    this.context = const [],
  });

  factory SearchedPlace.fromJson(Map<String, dynamic> json) {
    final coordinates = json['center'] as List;
    final context = <String>[];

    // Extract context (region/state, country, etc.) for better display
    if (json['context'] != null) {
      for (final ctx in json['context']) {
        final text = ctx['text'] as String;
        final id = ctx['id'] as String;

        // Include relevant context like region (state), country, etc.
        if (id.startsWith('region') ||
            id.startsWith('country') ||
            id.startsWith('district')) {
          context.add(text);
        }
      }
    }

    return SearchedPlace(
      placeName: json['place_name'] as String,
      shortName: json['text'] as String,
      longitude: (coordinates[0] as num).toDouble(),
      latitude: (coordinates[1] as num).toDouble(),
      category: json['properties']?['category'] as String?,
      address: json['properties']?['address'] as String?,
      context: context,
    );
  }

  factory SearchedPlace.fromCacheData(Map<String, dynamic> data) {
    return SearchedPlace(
      placeName: data['placeName'] as String,
      shortName: data['shortName'] as String,
      longitude: (data['longitude'] as num).toDouble(),
      latitude: (data['latitude'] as num).toDouble(),
      category: data['category'] as String?,
      address: data['address'] as String?,
      context: (data['context'] as List?)?.cast<String>() ?? <String>[],
    );
  }

  /// Get formatted location context (e.g., "Tennessee, United States")
  String get locationContext {
    if (context.isEmpty) return '';
    return context.join(', ');
  }

  /// Get display subtitle combining address and context
  String get displaySubtitle {
    final parts = <String>[];
    if (address != null && address!.isNotEmpty) {
      parts.add(address!);
    }
    if (locationContext.isNotEmpty) {
      parts.add(locationContext);
    }
    return parts.join(' • ');
  }

  IconData get categoryIcon {
    switch (category?.toLowerCase()) {
      case 'restaurant':
      case 'food':
        return CupertinoIcons.square_fill_on_circle_fill;
      case 'hotel':
      case 'lodging':
        return CupertinoIcons.bed_double;
      case 'gas':
      case 'fuel':
        return CupertinoIcons.car;
      case 'hospital':
      case 'medical':
        return CupertinoIcons.heart;
      case 'park':
      case 'recreation':
        return CupertinoIcons.tree;
      case 'shopping':
        return CupertinoIcons.bag;
      default:
        return CupertinoIcons.location;
    }
  }
}

/// Search service using your existing config
class MapSearchService {
  static Future<List<SearchedPlace>> searchPlaces({
    required String query,
    int limit = 8,
    bool usOnly = true, // Filter to US only by default
  }) async {
    if (query.trim().isEmpty) return [];

    try {
      final queryParams = {
        'access_token': AppConfig.mapboxPublicToken,
        'limit': limit.toString(),
        'autocomplete': 'true',
        'types':
            'country,region,place,district,locality,neighborhood,address,poi', // Include more place types
      };

      // Add country filter for US-only results
      if (usOnly) {
        queryParams['country'] = 'US';
      }

      final uri = Uri.parse(
        '${AppConfig.mapboxSearchApiUrl}${Uri.encodeComponent(query)}.json',
      ).replace(queryParameters: queryParams);

      final response = await http.get(uri).timeout(AppConfig.httpTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final features = data['features'] as List;
        return features
            .map((feature) => SearchedPlace.fromJson(feature))
            .toList();
      }
      return [];
    } catch (e) {
      print('❌ Search error: $e');
      return [];
    }
  }

  /// Convert coordinates to city, state using Mapbox Geocoding API
  static Future<Map<String, String?>> reverseGeocode(
    double latitude,
    double longitude,
  ) async {
    try {
      print('MAPBOX: Reverse geocoding $latitude, $longitude');

      final queryParams = {
        'access_token': AppConfig.mapboxPublicToken,
        'types': 'place,region', // Only get city and state level info
      };

      // Mapbox reverse geocoding URL: longitude,latitude (note order!)
      final uri = Uri.parse(
        '${AppConfig.mapboxSearchApiUrl}$longitude,$latitude.json',
      ).replace(queryParameters: queryParams);

      final response = await http.get(uri).timeout(AppConfig.httpTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final features = data['features'] as List;

        if (features.isNotEmpty) {
          String? city, state;

          // Look through all features to find city and state
          for (final feature in features) {
            final placeType = feature['place_type'] as List?;
            final text = feature['text'] as String?;
            final properties = feature['properties'] as Map?;

            if (placeType != null && text != null) {
              // City/locality
              if (placeType.contains('place') && city == null) {
                city = text;
              }
              // State/region
              else if (placeType.contains('region') && state == null) {
                // Try to get short code (e.g. "UT" from "Utah")
                final shortCode = properties?['short_code'] as String?;
                if (shortCode != null && shortCode.contains('-')) {
                  state = shortCode
                      .split('-')
                      .last
                      .toUpperCase(); // "US-UT" -> "UT"
                } else {
                  state = text; // Fall back to full name
                }
              }
            }
          }

          print('MAPBOX: ✅ Reverse geocoded to: $city, $state');
          return {'city': city, 'state': state};
        }
      } else {
        print('MAPBOX: API error ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      print('MAPBOX: ❌ Reverse geocoding failed: $e');
    }

    // Return null values on failure
    return {'city': null, 'state': null};
  }
}

/// Compact search bar for map overlay (like your existing bottom sheet pattern)
class CompactMapSearchBar extends StatelessWidget {
  final VoidCallback onTap;

  const CompactMapSearchBar({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.withOpacity(0.95),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.systemGrey.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.search,
              color: CupertinoColors.systemGrey,
              size: 20,
            ),
            const SizedBox(width: 12),
            const Text(
              'Search places...',
              style: TextStyle(
                color: CupertinoColors.placeholderText,
                fontSize: 16,
              ),
            ),
            const Spacer(),
            Icon(
              CupertinoIcons.location,
              color: CupertinoColors.systemBlue,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

/// Full search modal (follows your bottom sheet pattern)
class MapSearchModal extends StatefulWidget {
  final MapboxMap? mapboxMap;
  final Function(SearchedPlace)? onPlaceSelected;

  const MapSearchModal({super.key, this.mapboxMap, this.onPlaceSelected});

  @override
  State<MapSearchModal> createState() => _MapSearchModalState();
}

class _MapSearchModalState extends State<MapSearchModal> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<SearchedPlace> _searchResults = [];
  List<SearchedPlace> _recentSearches = [];
  bool _isSearching = false;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchTextChanged);
    // Auto-focus when modal opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
    // Load cached recent searches
    _loadRecentSearches();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadRecentSearches() async {
    try {
      final cachedSearches = await CacheService().getRecentSearches();
      final recentPlaces = cachedSearches
          .map((data) => SearchedPlace.fromCacheData(data))
          .take(4) // Limit to 4 items
          .toList();

      if (mounted) {
        setState(() {
          _recentSearches = recentPlaces;
        });
      }
    } catch (e) {
      print('❌ Error loading recent searches: $e');
    }
  }

  void _onSearchTextChanged() {
    final query = _searchController.text;
    _debounceTimer?.cancel();

    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() => _isSearching = true);

    try {
      final results = await MapSearchService.searchPlaces(
        query: query,
        usOnly: true, // Filter to US only
      );
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searchResults = [];
          _isSearching = false;
        });
      }
    }
  }

  void _selectPlace(SearchedPlace place) async {
    try {
      // Save to cache
      final searchData = {
        'placeName': place.placeName,
        'shortName': place.shortName,
        'longitude': place.longitude,
        'latitude': place.latitude,
        'category': place.category,
        'address': place.address,
        'context': place.context,
      };

      await CacheService().addRecentSearch(searchData);

      // Update UI list
      _recentSearches.removeWhere((p) => p.placeName == place.placeName);
      _recentSearches.insert(0, place);
      if (_recentSearches.length > 4) {
        _recentSearches = _recentSearches.take(4).toList();
      }
    } catch (e) {
      print('❌ Error saving recent search: $e');
      // Still update UI even if cache fails
      _recentSearches.removeWhere((p) => p.placeName == place.placeName);
      _recentSearches.insert(0, place);
      if (_recentSearches.length > 4) {
        _recentSearches = _recentSearches.take(4).toList();
      }
    }

    // Fly to location if map is available
    if (widget.mapboxMap != null) {
      _flyToPlace(place);
    }

    // Notify parent and close
    widget.onPlaceSelected?.call(place);
    Navigator.of(context).pop();
  }

  Future<void> _flyToPlace(SearchedPlace place) async {
    if (widget.mapboxMap == null) {
      print('❌ MapboxMap is null, cannot fly to place');
      return;
    }

    try {
      print(
        '🎯 Flying to: ${place.shortName} at ${place.latitude}, ${place.longitude}',
      );

      await widget.mapboxMap!.flyTo(
        CameraOptions(
          center: Point(
            coordinates: Position(
              place.longitude, // longitude first
              place.latitude, // latitude second
            ),
          ),
          zoom: 12.0,
        ),
        MapAnimationOptions(duration: 2000, startDelay: 0),
      );

      print('✅ Successfully flew to: ${place.shortName}');
    } catch (e) {
      print('❌ Error flying to place: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Column(
        children: [
          _buildHeader(),
          _buildSearchBar(),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
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
          Text(
            'Search Places',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const Spacer(),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.search,
            color: CupertinoColors.systemGrey.resolveFrom(context),
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: CupertinoTextField(
              controller: _searchController,
              focusNode: _focusNode,
              placeholder: 'Search places...',
              decoration: null,
              style: TextStyle(
                fontSize: 16,
                color: CupertinoColors.label.resolveFrom(context),
              ),
              placeholderStyle: TextStyle(
                color: CupertinoColors.placeholderText.resolveFrom(context),
              ),
            ),
          ),
          if (_isSearching) ...[
            const SizedBox(width: 8),
            const CupertinoActivityIndicator(radius: 8),
          ] else if (_searchController.text.isNotEmpty) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _searchController.clear(),
              child: Icon(
                CupertinoIcons.xmark_circle_fill,
                color: CupertinoColors.systemGrey3.resolveFrom(context),
                size: 20,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResults() {
    final hasResults = _searchResults.isNotEmpty;
    final hasRecent =
        _recentSearches.isNotEmpty && _searchController.text.isEmpty;

    if (!hasResults && !hasRecent) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.location_circle,
              size: 48,
              color: CupertinoColors.systemGrey3,
            ),
            const SizedBox(height: 12),
            Text(
              _searchController.text.isEmpty
                  ? 'Start typing to search'
                  : 'No places found',
              style: const TextStyle(
                color: CupertinoColors.secondaryLabel,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (hasResults) ...[
          if (_searchController.text.isNotEmpty) ...[
            const Text(
              'Search Results',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 8),
          ],
          ..._searchResults.map((place) => _buildPlaceItem(place)),
        ],
        if (hasRecent) ...[
          Text(
            'Recent Searches',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.systemGrey.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          ..._recentSearches.map(
            (place) => _buildPlaceItem(place, isRecent: true),
          ),
        ],
        // Bottom padding for safe area
        SizedBox(height: MediaQuery.of(context).padding.bottom),
      ],
    );
  }

  Widget _buildPlaceItem(SearchedPlace place, {bool isRecent = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.separator.withOpacity(0.5),
            width: 0.5,
          ),
        ),
      ),
      child: CupertinoListTile(
        padding: const EdgeInsets.symmetric(vertical: 12),
        leading: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: isRecent
                ? CupertinoColors.systemGrey5
                : CupertinoColors.systemBlue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            isRecent ? CupertinoIcons.clock : place.categoryIcon,
            size: 18,
            color: isRecent
                ? CupertinoColors.systemGrey
                : CupertinoColors.systemBlue,
          ),
        ),
        title: Text(
          place.shortName,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: place.displaySubtitle.isNotEmpty
            ? Text(
                place.displaySubtitle,
                style: TextStyle(
                  fontSize: 14,
                  color: CupertinoColors.systemGrey2.resolveFrom(context),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        trailing: Icon(
          CupertinoIcons.chevron_right,
          size: 16,
          color: CupertinoColors.systemGrey2,
        ),
        onTap: () => _selectPlace(place),
      ),
    );
  }
}

/// Helper function to show search modal (follows your existing pattern)
void showMapSearchModal(
  BuildContext context, {
  MapboxMap? mapboxMap,
  Function(SearchedPlace)? onPlaceSelected,
}) {
  showCupertinoModalPopup(
    context: context,
    builder: (context) =>
        MapSearchModal(mapboxMap: mapboxMap, onPlaceSelected: onPlaceSelected),
  );
}
