// lib/ui/2_presentation/features/favorites/widgets/favorites_search_bar.dart

import 'package:flutter/cupertino.dart';

/// Pull-down search bar for favorites list
/// Hidden by default, appears when user pulls down and has 4+ favorites
class FavoritesSearchBar extends StatefulWidget {
  final Function(String) onSearchChanged;
  final bool isVisible;
  final VoidCallback? onCancel;
  final String? placeholder;

  const FavoritesSearchBar({
    super.key,
    required this.onSearchChanged,
    required this.isVisible,
    this.onCancel,
    this.placeholder,
  });

  @override
  State<FavoritesSearchBar> createState() => _FavoritesSearchBarState();
}

class _FavoritesSearchBarState extends State<FavoritesSearchBar>
    with TickerProviderStateMixin {
  late TextEditingController _searchController;
  late FocusNode _focusNode;
  late AnimationController _animationController;
  late Animation<double> _heightAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _focusNode = FocusNode();

    // Setup animations
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _heightAnimation =
        Tween<double>(
          begin: 0.0,
          end: 60.0, // Height when visible
        ).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeInOut,
          ),
        );

    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // Listen to search changes
    _searchController.addListener(_onSearchChanged);

    // Show/hide based on initial visibility
    if (widget.isVisible) {
      _animationController.forward();
    }
  }

  @override
  void didUpdateWidget(FavoritesSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Handle visibility changes
    if (widget.isVisible != oldWidget.isVisible) {
      if (widget.isVisible) {
        _animationController.forward();
        // Auto-focus when becoming visible
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted && _focusNode.canRequestFocus) {
            _focusNode.requestFocus();
          }
        });
      } else {
        _animationController.reverse();
        _clearSearch();
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    widget.onSearchChanged(_searchController.text);
  }

  void _clearSearch() {
    _searchController.clear();
    _focusNode.unfocus();
    widget.onSearchChanged('');
  }

  void _handleCancel() {
    _clearSearch();
    widget.onCancel?.call();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return SizedBox(
          height: _heightAnimation.value,
          child: Opacity(
            opacity: _opacityAnimation.value,
            child: _buildSearchContent(),
          ),
        );
      },
    );
  }

  Widget _buildSearchContent() {
    if (_heightAnimation.value == 0) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // Search field
          Expanded(
            child: CupertinoSearchTextField(
              controller: _searchController,
              focusNode: _focusNode,
              placeholder: widget.placeholder ?? 'Search favorites...',
              style: const TextStyle(fontSize: 16),
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey6.resolveFrom(context),
                borderRadius: BorderRadius.circular(10),
              ),
              onChanged: (value) {
                // onChanged is handled by the controller listener
                // but we can add additional logic here if needed
              },
              onSubmitted: (value) {
                // Handle search submission if needed
              },
            ),
          ),

          // Cancel button (appears when search is active)
          if (_searchController.text.isNotEmpty) ...[
            const SizedBox(width: 8),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              onPressed: _handleCancel,
              child: const Text(
                'Cancel',
                style: TextStyle(
                  color: CupertinoColors.activeBlue,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Wrapper widget that handles the pull-down reveal logic
/// Integrates with ScrollView to show search bar on overscroll
class PullDownSearchWrapper extends StatefulWidget {
  final Widget child;
  final Function(String) onSearchChanged;
  final bool shouldShowSearch; // Based on favorites count >= 4
  final String? searchPlaceholder;

  const PullDownSearchWrapper({
    super.key,
    required this.child,
    required this.onSearchChanged,
    required this.shouldShowSearch,
    this.searchPlaceholder,
  });

  @override
  State<PullDownSearchWrapper> createState() => _PullDownSearchWrapperState();
}

class _PullDownSearchWrapperState extends State<PullDownSearchWrapper> {
  bool _isSearchVisible = false;
  bool _isOverscrolling = false;
  double _overscrollAmount = 0.0;

  // Threshold for revealing search (pixels pulled down)
  static const double _revealThreshold = 60.0;

  @override
  Widget build(BuildContext context) {
    if (!widget.shouldShowSearch) {
      // If we don't have 4+ favorites, just show the child
      return widget.child;
    }

    return Column(
      children: [
        // Search bar (animated visibility)
        FavoritesSearchBar(
          onSearchChanged: widget.onSearchChanged,
          isVisible: _isSearchVisible,
          onCancel: _hideSearch,
          placeholder: widget.searchPlaceholder,
        ),

        // Main content with scroll detection
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _handleScrollNotification,
            child: widget.child,
          ),
        ),
      ],
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!widget.shouldShowSearch) return false;

    if (notification is ScrollUpdateNotification) {
      final overscroll = notification.metrics.pixels;

      // Check if we're overscrolling at the top
      if (overscroll < 0 && !_isSearchVisible) {
        setState(() {
          _isOverscrolling = true;
          _overscrollAmount = overscroll.abs();
        });

        // Reveal search bar if pulled down far enough
        if (_overscrollAmount > _revealThreshold) {
          _showSearch();
        }
      } else if (overscroll >= 0 && _isOverscrolling) {
        setState(() {
          _isOverscrolling = false;
          _overscrollAmount = 0.0;
        });
      }
    } else if (notification is ScrollEndNotification) {
      setState(() {
        _isOverscrolling = false;
        _overscrollAmount = 0.0;
      });
    }

    return false; // Allow other listeners to process
  }

  void _showSearch() {
    if (!_isSearchVisible && widget.shouldShowSearch) {
      setState(() {
        _isSearchVisible = true;
      });
    }
  }

  void _hideSearch() {
    if (_isSearchVisible) {
      setState(() {
        _isSearchVisible = false;
      });
    }
  }
}

/// Simple search bar that's always visible (alternative implementation)
/// Use this if the pull-down behavior is too complex
class AlwaysVisibleSearchBar extends StatefulWidget {
  final Function(String) onSearchChanged;
  final String? placeholder;

  const AlwaysVisibleSearchBar({
    super.key,
    required this.onSearchChanged,
    this.placeholder,
  });

  @override
  State<AlwaysVisibleSearchBar> createState() => _AlwaysVisibleSearchBarState();
}

class _AlwaysVisibleSearchBarState extends State<AlwaysVisibleSearchBar> {
  late TextEditingController _searchController;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _focusNode = FocusNode();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    widget.onSearchChanged(_searchController.text);
  }

  void _clearSearch() {
    _searchController.clear();
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: CupertinoColors.systemBackground,
        border: Border(
          bottom: BorderSide(color: CupertinoColors.separator, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: CupertinoSearchTextField(
              controller: _searchController,
              focusNode: _focusNode,
              placeholder: widget.placeholder ?? 'Search favorites...',
              style: const TextStyle(fontSize: 16),
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey6,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),

          if (_searchController.text.isNotEmpty) ...[
            const SizedBox(width: 8),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              onPressed: _clearSearch,
              child: const Text(
                'Clear',
                style: TextStyle(
                  color: CupertinoColors.activeBlue,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
