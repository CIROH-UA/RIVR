// lib/features/map/widgets/streams_list_bottom_sheet.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../../core/constants.dart';
import '../models/visible_stream.dart';

/// Bottom sheet showing list of visible streams with search functionality
class StreamsListBottomSheet extends StatefulWidget {
  final List<VisibleStream> streams;
  final Function(VisibleStream) onStreamSelected;

  const StreamsListBottomSheet({
    super.key,
    required this.streams,
    required this.onStreamSelected,
  });

  @override
  State<StreamsListBottomSheet> createState() => _StreamsListBottomSheetState();
}

class _StreamsListBottomSheetState extends State<StreamsListBottomSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<VisibleStream> _filteredStreams = [];

  @override
  void initState() {
    super.initState();
    _filteredStreams = widget.streams;
    _searchController.addListener(_filterStreams);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterStreams() {
    final query = _searchController.text.toLowerCase().trim();

    setState(() {
      if (query.isEmpty) {
        _filteredStreams = widget.streams;
      } else {
        _filteredStreams = widget.streams.where((stream) {
          return stream.stationId.toLowerCase().contains(query) ||
              (stream.riverName?.toLowerCase().contains(query) ?? false);
        }).toList();
      }
    });
  }

  void _onStreamTap(VisibleStream stream) {
    Navigator.pop(context); // Close bottom sheet
    widget.onStreamSelected(stream); // Fly to stream
  }

  @override
  Widget build(BuildContext context) {
    final brightness = MediaQuery.of(context).platformBrightness;
    final isDark = brightness == Brightness.dark;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75, // 75% of screen height
      decoration: BoxDecoration(
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _buildHeader(isDark),
            _buildSearchBar(isDark),
            Expanded(child: _buildStreamsList()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: CupertinoColors.systemBlue
                  .resolveFrom(context)
                  .withValues(alpha: isDark ? 0.15 : 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              CupertinoIcons.list_bullet,
              color: CupertinoColors.systemBlue.resolveFrom(context),
              size: 24,
            ),
          ),
          const SizedBox(width: 12),

          // Title and count
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Visible Streams',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                Text(
                  '${widget.streams.length} stream${widget.streams.length == 1 ? '' : 's'} in view',
                  style: TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),

          // Close button
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.pop(context),
            child: Icon(
              CupertinoIcons.xmark_circle_fill,
              color: CupertinoColors.systemGrey3.resolveFrom(context),
              size: 24,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        16,
        0,
        16,
        0,
      ), // Reduced bottom padding from 16 to 8
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? CupertinoColors.systemGrey5.resolveFrom(context)
              : CupertinoColors.systemGrey6.resolveFrom(context),
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
                placeholder: 'Search by station ID...',
                placeholderStyle: TextStyle(
                  color: CupertinoColors.placeholderText.resolveFrom(context),
                ),
                decoration: null,
                style: TextStyle(
                  fontSize: 16,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
                padding: EdgeInsets.zero,
              ),
            ),
            if (_searchController.text.isNotEmpty)
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () {
                  _searchController.clear();
                },
                child: Icon(
                  CupertinoIcons.clear_circled_solid,
                  color: CupertinoColors.systemGrey3.resolveFrom(context),
                  size: 18,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreamsList() {
    if (_filteredStreams.isEmpty) {
      return _buildEmptyState();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          const SizedBox(height: 8), // Reduced from 16 to 8
          // Results count
          if (_searchController.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8), // Reduced from 12 to 8
              child: Row(
                children: [
                  Text(
                    '${_filteredStreams.length} result${_filteredStreams.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: 14,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          // List
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              primary: false,
              itemCount: _filteredStreams.length,
              separatorBuilder: (context, index) => Divider(
                height: 1,
                color: CupertinoColors.separator.resolveFrom(context),
              ),
              itemBuilder: (context, index) {
                final stream = _filteredStreams[index];
                return _buildStreamItem(stream);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStreamItem(VisibleStream stream) {
    final brightness = MediaQuery.of(context).platformBrightness;
    final isDark = brightness == Brightness.dark;

    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      onPressed: () => _onStreamTap(stream),
      child: Row(
        children: [
          // Stream order icon
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppConstants.getStreamOrderColor(
                stream.streamOrder,
              ).withValues(alpha: isDark ? 0.15 : 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              AppConstants.getStreamOrderIcon(stream.streamOrder),
              color: AppConstants.getStreamOrderColor(stream.streamOrder),
              size: 16,
            ),
          ),
          const SizedBox(width: 12),

          // Stream info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stream.displayName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Station ${stream.stationId} • Order ${stream.streamOrder}',
                  style: TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  stream.coordinates,
                  style: TextStyle(
                    fontSize: 12,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                    fontFamily: 'SF Mono', // Monospace for coordinates
                  ),
                ),
              ],
            ),
          ),

          // Arrow indicator
          Icon(
            CupertinoIcons.location_fill,
            color: CupertinoColors.systemBlue.resolveFrom(context),
            size: 16,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _searchController.text.isNotEmpty
                  ? CupertinoIcons.search
                  : CupertinoIcons.list_bullet,
              size: 48,
              color: CupertinoColors.systemGrey3.resolveFrom(context),
            ),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isNotEmpty
                  ? 'No streams found'
                  : 'No streams visible',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isNotEmpty
                  ? 'Try a different search term'
                  : 'Zoom in or pan to see streams',
              style: TextStyle(
                fontSize: 14,
                color: CupertinoColors.tertiaryLabel.resolveFrom(context),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Helper function to show the streams list modal
void showStreamsListModal(
  BuildContext context, {
  required List<VisibleStream> streams,
  required Function(VisibleStream) onStreamSelected,
}) {
  showCupertinoModalPopup(
    context: context,
    builder: (context) => StreamsListBottomSheet(
      streams: streams,
      onStreamSelected: onStreamSelected,
    ),
  );
}
