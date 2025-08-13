// lib/features/favorites/favorites_page.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:rivrflow/core/providers/reach_data_provider.dart';
import 'package:rivrflow/core/services/flow_unit_preference_service.dart';
import 'package:rivrflow/features/auth/providers/auth_provider.dart';
import 'package:rivrflow/features/favorites/widgets/favorite_river_card.dart';
import 'package:rivrflow/features/favorites/widgets/favorites_search_bar.dart';
import '../../../core/providers/favorites_provider.dart';
import '../../../core/models/favorite_river.dart';
// ADD: Import the services and models for flow unit handling
import '../../../features/auth/services/user_settings_service.dart';
import '../../../core/models/user_settings.dart';

/// Main favorites page - serves as app home screen
/// Features: reorderable list, pull-to-refresh, search, empty state
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  String _searchQuery = '';
  bool _isRefreshing = false;
  bool _showSearch = false; // New state for search visibility
  String _selectedFlowUnit = 'CFS';

  @override
  void initState() {
    super.initState();
    // Initialize favorites when page loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeFavorites();
      _loadUserFlowUnitPreference(); // ADD: Load user's current preference
    });
  }

  Future<void> _initializeFavorites() async {
    final authProvider = context.read<AuthProvider>();
    if (!authProvider.isAuthenticated) return;

    final favoritesProvider = context.read<FavoritesProvider>();
    await favoritesProvider.initializeAndRefresh();
  }

  // ADD: Load user's current flow unit preference
  Future<void> _loadUserFlowUnitPreference() async {
    try {
      final authProvider = context.read<AuthProvider>();
      final userId = authProvider.currentUser?.uid;

      if (userId != null) {
        final userSettings = await UserSettingsService().getUserSettings(
          userId,
        );
        if (userSettings != null && mounted) {
          setState(() {
            _selectedFlowUnit = userSettings.preferredFlowUnit == FlowUnit.cms
                ? 'CMS'
                : 'CFS';
          });
        }
      }
    } catch (e) {
      print('FAVORITES_PAGE: Error loading flow unit preference: $e');
      // Keep default CFS if loading fails
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: _buildNavigationBar(),
      child: Stack(
        children: [
          // Main content
          Consumer<FavoritesProvider>(
            builder: (context, favoritesProvider, child) {
              if (favoritesProvider.isLoading) {
                return _buildLoadingState();
              }

              if (favoritesProvider.isEmpty) {
                return _buildEmptyState();
              }

              return _buildFavoritesList(favoritesProvider);
            },
          ),

          // Floating action button
          _buildFloatingActionButton(),
        ],
      ),
    );
  }

  CupertinoNavigationBar _buildNavigationBar() {
    return CupertinoNavigationBar(
      // No middle title anymore
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: _showSettingsMenu,
        child: const Icon(CupertinoIcons.ellipsis),
      ),
    );
  }

  Widget _buildFloatingActionButton() {
    return Positioned(
      bottom: 50,
      right: 20,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: _navigateToMap,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: CupertinoColors.systemBlue.resolveFrom(context),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: CupertinoColors.black.withOpacity(0.2),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            CupertinoIcons.add,
            color: CupertinoDynamicColor.resolve(
              CupertinoColors.white,
              context,
            ),
            size: 24,
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CupertinoActivityIndicator(radius: 16),
          SizedBox(height: 16),
          Text(
            'Loading your rivers...',
            style: TextStyle(fontSize: 16, color: CupertinoColors.systemGrey),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return SafeArea(
      child: Column(
        children: [
          // App title header
          _buildAppHeader(),

          // Empty state content
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Empty state illustration
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemBlue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(60),
                      ),
                      child: const Icon(
                        CupertinoIcons.heart,
                        size: 60,
                        color: CupertinoColors.systemBlue,
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Title
                    const Text(
                      'No Favorite Rivers Yet',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.label,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 12),

                    // Description
                    Text(
                      'Discover rivers on the map and add them to your favorites for quick access to flow forecasts.',
                      style: TextStyle(
                        fontSize: 16,
                        color: CupertinoColors.systemGrey2
                          ..resolveFrom(context),
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 32),

                    // Call to action button
                    CupertinoButton.filled(
                      onPressed: _navigateToMap,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(CupertinoIcons.map, size: 18),
                          SizedBox(width: 8),
                          Text('Explore Rivers'),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Secondary action
                    CupertinoButton(
                      onPressed: _showHelpDialog,
                      child: const Text('How do I add favorites?'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFavoritesList(FavoritesProvider favoritesProvider) {
    final filteredFavorites = _searchQuery.isEmpty
        ? favoritesProvider.favorites
        : favoritesProvider.filterFavorites(_searchQuery);

    return SafeArea(
      top: true,
      child: Column(
        children: [
          // App header
          _buildAppHeader(),

          // Search bar (using custom FavoritesSearchBar)
          Consumer<FavoritesProvider>(
            builder: (context, favoritesProvider, child) {
              if (favoritesProvider.shouldShowSearch) {
                return FavoritesSearchBar(
                  onSearchChanged: (query) {
                    // Defer setState to avoid build-time conflicts
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        setState(() => _searchQuery = query);
                      }
                    });
                  },
                  isVisible: _showSearch,
                  onCancel: () {
                    // Defer setState to avoid build-time conflicts
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        setState(() {
                          _showSearch = false;
                          _searchQuery = '';
                        });
                      }
                    });
                  },
                  placeholder: 'Search your rivers...',
                );
              }
              return const SizedBox.shrink();
            },
          ),

          // Favorites list
          Expanded(
            child: CustomScrollView(
              slivers: [
                // Pull-to-refresh
                CupertinoSliverRefreshControl(
                  onRefresh: () => _handleRefresh(favoritesProvider),
                ),

                // Error message (if any)
                if (favoritesProvider.errorMessage != null)
                  SliverToBoxAdapter(
                    child: _buildErrorBanner(favoritesProvider.errorMessage!),
                  ),

                // Search results info (when searching)
                if (_searchQuery.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _buildSearchResultsHeader(filteredFavorites.length),
                  ),

                // Favorites list
                SliverToBoxAdapter(
                  child: _buildReorderableList(
                    filteredFavorites,
                    favoritesProvider,
                  ),
                ),

                // Bottom padding for floating action button
                const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 32, 16),
      child: Row(
        children: [
          // App title with theme-aware color
          Text(
            'RivrFlow',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: CupertinoTheme.of(context).textTheme.textStyle.color,
            ),
          ),

          const Spacer(),

          // Search toggle button (only when 4+ favorites and not empty state)
          Consumer<FavoritesProvider>(
            builder: (context, favoritesProvider, child) {
              if (favoritesProvider.shouldShowSearch &&
                  !favoritesProvider.isEmpty) {
                return CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _toggleSearch,
                  child: Icon(
                    _showSearch
                        ? CupertinoIcons.xmark_circle_fill
                        : CupertinoIcons.search,
                    color: CupertinoColors.systemBlue,
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String errorMessage) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CupertinoColors.systemRed.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: CupertinoColors.systemRed.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.exclamationmark_triangle,
            color: CupertinoColors.systemRed,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              errorMessage,
              style: const TextStyle(
                color: CupertinoColors.systemRed,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResultsHeader(int resultCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        resultCount == 1 ? '1 river found' : '$resultCount rivers found',
        style: const TextStyle(
          fontSize: 14,
          color: CupertinoColors.secondaryLabel,
        ),
      ),
    );
  }

  Widget _buildReorderableList(
    List<FavoriteRiver> favorites,
    FavoritesProvider favoritesProvider,
  ) {
    if (favorites.isEmpty && _searchQuery.isNotEmpty) {
      return _buildNoSearchResults();
    }

    return ReorderableListView.builder(
      shrinkWrap: true,
      // Revert to original physics - works better with nested CustomScrollView
      physics:
          const NeverScrollableScrollPhysics(), // Let parent CustomScrollView handle scrolling
      itemCount: favorites.length,
      onReorder: (oldIndex, newIndex) =>
          _handleReorder(oldIndex, newIndex, favoritesProvider),
      proxyDecorator: _proxyDecorator,
      padding: const EdgeInsets.only(bottom: 20),
      onReorderStart: (index) {
        HapticFeedback.mediumImpact();
      },
      onReorderEnd: (index) {
        HapticFeedback.lightImpact();
      },
      itemBuilder: (context, index) {
        final favorite = favorites[index];
        return FavoriteRiverCard(
          key: ValueKey(favorite.reachId),
          favorite: favorite,
          onTap: () => _navigateToForecast(favorite.reachId),
          onRename: () => _showRenameDialog(favorite),
          onChangeImage: () => _navigateToImageSelection(favorite),
          isReorderable: _searchQuery.isEmpty,
        );
      },
    );
  }

  Widget _buildNoSearchResults() {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(
            CupertinoIcons.search,
            size: 48,
            color: CupertinoColors.systemGrey.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No rivers found for "$_searchQuery"',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: CupertinoColors.secondaryLabel,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Try searching by river name or reach ID',
            style: TextStyle(
              fontSize: 14,
              color: CupertinoColors.tertiaryLabel,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _proxyDecorator(Widget child, int index, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        // Scale stays consistent during drag (smaller = "grabbed")
        return Transform.scale(
          scale: 0.95, // Slightly smaller to show "grabbed" state
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                // More pronounced shadow during drag
                BoxShadow(
                  color: CupertinoColors.black.withOpacity(0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  // Enhanced error handling in the async method
  Future<void> _updateFlowUnitAsync(String value) async {
    try {
      final authProvider = context.read<AuthProvider>();
      final userId = authProvider.currentUser?.uid;

      if (userId != null) {
        // Update user settings with new flow unit
        final flowUnit = value == 'CMS' ? FlowUnit.cms : FlowUnit.cfs;

        await UserSettingsService().updateFlowUnit(userId, flowUnit);
        FlowUnitPreferenceService().setFlowUnit(value);

        // Clear unit-dependent caches
        // This forces the Current Flow Status Card to recalculate with new units
        final reachProvider = context.read<ReachDataProvider>();
        reachProvider.clearUnitDependentCaches();

        // Force UI rebuild
        if (mounted) {
          setState(() {
            // This triggers rebuild of favorites page river cards
          });
        }
      } else {
        // Revert UI state if no user
        if (mounted) {
          setState(() {
            _selectedFlowUnit = _selectedFlowUnit == 'CFS' ? 'CMS' : 'CFS';
          });
        }
      }
    } catch (e) {
      // Revert UI state on error
      if (mounted) {
        setState(() {
          _selectedFlowUnit = _selectedFlowUnit == 'CFS' ? 'CMS' : 'CFS';
        });

        // Show error to user
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Update Failed'),
            content: Text('Error: $e'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      }
    }
  }

  // Event handlers
  Future<void> _handleRefresh(FavoritesProvider favoritesProvider) async {
    if (_isRefreshing) return;

    setState(() {
      _isRefreshing = true;
    });

    try {
      await favoritesProvider.refreshAllFavorites();
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _handleReorder(
    int oldIndex,
    int newIndex,
    FavoritesProvider favoritesProvider,
  ) async {
    // Adjust newIndex if needed (ReorderableListView quirk)
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }

    await favoritesProvider.reorderFavorites(oldIndex, newIndex);
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _searchQuery = ''; // Clear search when hiding
      }
    });
  }

  void _showSettingsMenu() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Settings Menu',
      barrierColor: CupertinoColors.black.withOpacity(0.3),
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, animation, secondaryAnimation) {
        return FadeTransition(opacity: animation, child: _buildDropdownMenu());
      },
    );
  }

  Widget _buildDropdownMenu() {
    return StatefulBuilder(
      builder: (context, setModalState) {
        return SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Container(
              margin: const EdgeInsets.only(top: 30, right: 30),
              width: 250,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: CupertinoColors.black.withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMenuOption('Notifications', CupertinoIcons.bell, () {
                    Navigator.pop(context);
                    Navigator.of(context).pushNamed('/notifications-settings');
                  }),
                  _buildMenuDivider(),
                  _buildFlowUnitsToggleWithModalState(setModalState),
                  _buildMenuDivider(),
                  _buildMenuOption('App Theme', CupertinoIcons.moon, () {
                    Navigator.pop(context);
                    Navigator.of(context).pushNamed('/app-theme-settings');
                  }),
                  _buildMenuDivider(),
                  _buildMenuOption('Sponsors', CupertinoIcons.creditcard, () {
                    Navigator.pop(context);
                    Navigator.of(context).pushNamed('/sponsors');
                  }),
                  _buildMenuDivider(color: CupertinoColors.systemGrey),
                  _buildSignOutOption(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFlowUnitsToggleWithModalState(StateSetter setModalState) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 16, 16, 16),
      child: Row(
        children: [
          CupertinoSlidingSegmentedControl<String>(
            groupValue: _selectedFlowUnit,
            onValueChanged: (String? value) {
              if (value != null && value != _selectedFlowUnit) {
                // Update both the page state AND modal state
                setState(() {
                  _selectedFlowUnit = value;
                });
                setModalState(() {
                  _selectedFlowUnit = value;
                });
                _updateFlowUnitAsync(value);
              }
            },
            children: const {
              'CFS': Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('CFS', style: TextStyle(fontSize: 13)),
              ),
              'CMS': Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('CMS', style: TextStyle(fontSize: 13)),
              ),
            },
          ),
          const Spacer(),
          Icon(CupertinoIcons.drop, color: CupertinoColors.white, size: 22),
        ],
      ),
    );
  }

  Widget _buildSignOutOption() {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, child) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // User info section
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  // User icon
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemBrown,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      CupertinoIcons.person_fill,
                      color: CupertinoColors.systemBackground,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // User name
                  Expanded(
                    child: Text(
                      authProvider.userDisplayName,
                      style: const TextStyle(
                        color: CupertinoColors.systemGrey,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Sign out button
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () async {
                Navigator.pop(context); // Close menu first
                await _handleSignOut(authProvider);
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.only(bottom: 10, left: 16, right: 16),
                child: Row(
                  children: [
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: Text(
                        'Sign Out',
                        style: TextStyle(
                          color: authProvider.isLoading
                              ? CupertinoColors.systemGrey
                              : CupertinoColors.systemRed,
                          fontSize: 17,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),

                    authProvider.isLoading
                        ? const CupertinoActivityIndicator(
                            radius: 8,
                            color: CupertinoColors.systemGrey,
                          )
                        : const Icon(
                            CupertinoIcons.square_arrow_right,
                            color: CupertinoColors.systemRed,
                            size: 22,
                          ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMenuOption(String title, IconData icon, VoidCallback onTap) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 17,
                fontWeight: FontWeight.w400,
              ),
            ),
            const Spacer(),
            Icon(icon, color: CupertinoColors.white, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuDivider({Color? color}) {
    return Container(
      height: 1,
      color:
          color ??
          CupertinoColors.separator.withOpacity(
            0.3,
          ), // Use provided color or default
      margin: EdgeInsets.symmetric(horizontal: 16),
    );
  }

  void _navigateToMap() {
    Navigator.of(context).pushNamed('/map');
  }

  void _navigateToForecast(String reachId) {
    Navigator.of(context).pushNamed('/forecast', arguments: reachId);
  }

  void _navigateToImageSelection(FavoriteRiver favorite) {
    Navigator.of(
      context,
    ).pushNamed('/image-selection', arguments: favorite.reachId);
  }

  void _showRenameDialog(FavoriteRiver favorite) {
    final controller = TextEditingController(text: favorite.customName);

    // Check if there's a default name to restore to
    final hasDefaultName =
        favorite.riverName != null && favorite.riverName!.isNotEmpty;
    final defaultName = favorite.riverName ?? 'Station ${favorite.reachId}';

    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Rename River'),
        content: Column(
          children: [
            const SizedBox(height: 16),
            CupertinoTextField(
              controller: controller,
              placeholder: 'Enter new name',
              textAlign: TextAlign.center,
              autofocus: true,
            ),
            if (hasDefaultName && favorite.customName != null) ...[
              const SizedBox(height: 12),
              CupertinoButton(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                onPressed: () {
                  controller.text = defaultName;
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CupertinoIcons.refresh_circled,
                      size: 16,
                      color: CupertinoColors.systemBlue,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Restore to "$defaultName"',
                      style: TextStyle(
                        fontSize: 14,
                        color: CupertinoColors.systemBlue,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            onPressed: () async {
              final newName = controller.text.trim();
              Navigator.pop(context);

              if (newName.isNotEmpty && newName != favorite.customName) {
                final provider = context.read<FavoritesProvider>();
                await provider.updateFavorite(
                  favorite.reachId,
                  customName: newName,
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSignOut(AuthProvider authProvider) async {
    // Show confirmation dialog
    final shouldSignOut = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out of RivrFlow?'),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Sign Out'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    // If user confirmed, proceed with sign out
    if (shouldSignOut == true) {
      try {
        await authProvider.signOut();
        // AuthCoordinator will automatically handle navigation back to auth
      } catch (e) {
        print('FAVORITES_PAGE: Error signing out: $e');

        // Show error dialog
        if (mounted) {
          showCupertinoDialog(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: const Text('Sign Out Error'),
              content: const Text('Unable to sign out. Please try again.'),
              actions: [
                CupertinoDialogAction(
                  child: const Text('OK'),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          );
        }
      }
    }
  }

  void _showHelpDialog() {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Adding Favorites'),
        content: const Text(
          '1. Tap the + button to open the map\n'
          '2. Find a river you\'re interested in\n'
          '3. Tap the river to view details\n'
          '4. Tap the heart button to add it to favorites\n\n'
          'Your favorites will appear here for quick access to flow forecasts.',
          textAlign: TextAlign.center,
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
          CupertinoDialogAction(
            onPressed: () {
              Navigator.pop(context);
              _navigateToMap();
            },
            child: const Text('Explore Now'),
          ),
        ],
      ),
    );
  }
}
