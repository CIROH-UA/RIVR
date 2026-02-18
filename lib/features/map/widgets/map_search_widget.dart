// lib/features/map/widgets/map_search_widget.dart

import 'package:flutter/cupertino.dart';
import 'dart:async';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import '../../../core/services/cache_service.dart';
import '../../../core/services/app_logger.dart';
import '../services/map_search_service.dart';

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
      AppLogger.error('MapSearchWidget', 'Error loading recent searches', e);
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
      AppLogger.error('MapSearchWidget', 'Error saving recent search', e);
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
      AppLogger.error('MapSearchWidget', 'MapboxMap is null, cannot fly to place');
      return;
    }

    try {
      AppLogger.debug(
        'MapSearchWidget',
        'Flying to: ${place.shortName} at ${place.latitude}, ${place.longitude}',
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

      AppLogger.info('MapSearchWidget', 'Successfully flew to: ${place.shortName}');
    } catch (e) {
      AppLogger.error('MapSearchWidget', 'Error flying to place', e);
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
