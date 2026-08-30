// lib/ui/2_presentation/features/favorites/pages/favorites_page.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:provider/provider.dart';
import 'package:rivr/utils/startup_trace.dart';
import 'package:rivr/ui/1_state/features/forecast/reach_data_provider.dart';
import 'package:rivr/ui/2_presentation/routing/route_observer.dart';
import 'package:rivr/services/1_contracts/shared/i_flow_unit_preference_service.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';
import 'package:rivr/ui/2_presentation/routing/app_router.dart';
import 'package:rivr/ui/1_state/features/auth/auth_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';
import 'package:rivr/services/4_infrastructure/favorites/coach_mark_service.dart';
import 'package:rivr/services/4_infrastructure/favorites/coach_mark_targets.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/favorite_river_card.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/favorites_search_bar.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/skeleton_river_card.dart';
import 'package:rivr/ui/2_presentation/shared/widgets/sync_status_banner.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/notification_prompt_banner.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/models/1_domain/shared/forecast_source.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/services/1_contracts/shared/i_fcm_service.dart';
import 'package:rivr/services/1_contracts/shared/i_user_settings_service.dart';
import 'package:rivr/models/1_domain/shared/alert_frequency.dart';
import 'package:rivr/models/1_domain/shared/favorite_label_key.dart';
import 'package:rivr/models/1_domain/shared/user_settings.dart';

/// Main favorites page - serves as app home screen
/// Features: reorderable list, pull-to-refresh, search, empty state
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with WidgetsBindingObserver, RouteAware {
  String _searchQuery = '';
  bool _isRefreshing = false;
  bool _showSearch = false; // New state for search visibility
  String _selectedFlowUnit = 'ft³/s';
  bool _notificationBannerDismissed = true; // Default hidden until loaded
  DateTime? _lastBackPressTime;

  static const _bannerDismissedKey = 'notification_banner_dismissed';

  /// The OS permission on this device. The card is only worth showing when the
  /// system prompt is still available — asking someone who already granted is
  /// noise, and asking someone the OS has refused is a button that cannot work.
  NotificationPermissionResult? _osPermission;

  // Coach mark keys
  final GlobalKey _settingsButtonKey = GlobalKey();
  final GlobalKey _firstCardKey = GlobalKey();
  final GlobalKey _searchIconKey = GlobalKey();

  // Coach mark state
  bool _hasShownFavoritesTour = true; // Default true until loaded
  bool _hasShownSearchTip = true;
  bool _isTourActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize favorites when page loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeFavorites();
      _loadUserFlowUnitPreference();
      _loadMutedReaches();
      _loadBannerDismissalState();
      _loadOsPermission();
      _checkAndShowCoachMarks();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to route changes so we revalidate when this list becomes
    // visible again (e.g. after popping the forecast page).
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Called when a route pushed on top of the favorites list is popped —
  /// i.e. the user returned to the list (e.g. from the forecast page).
  @override
  void didPopNext() => _revalidateOnView();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _revalidateOnView();
  }

  /// Silently re-read every favorite through the repository so the cards
  /// reflect the freshest run whenever the list becomes visible. The cards
  /// otherwise show a persisted snapshot that can lag the forecast page's live
  /// value; revalidating on view keeps the home number in step with what a tap
  /// opens. Cheap: the repository serves fresh-cached entries without a network
  /// call and only revalidates stale ones.
  void _revalidateOnView() {
    if (!mounted) return;
    final authProvider = context.read<AuthProvider>();
    if (!authProvider.isAuthenticated) return;
    context.read<FavoritesProvider>().refreshAllFavorites();
  }

  /// "Not now" is not "never". A permanent dismissal meant one distracted tap
  /// cost the user notifications forever, with no way back except finding the
  /// settings page. The ask returns after this window (ADR 0009, phase 2).
  static const Duration _dismissalWindow = Duration(days: 30);

  Future<void> _loadOsPermission() async {
    final p = await GetIt.I<IFCMService>().osPermissionStatus();
    if (mounted) setState(() => _osPermission = p);
  }

  Future<void> _loadBannerDismissalState() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_bannerDismissedKey);
    // Legacy bool from builds before the window existed — treat as dismissed
    // now, so those users get asked again in 30 days rather than never.
    final legacy = prefs.getBool('${_bannerDismissedKey}_legacy') ??
        (ms == null ? prefs.getBool(_bannerDismissedKey) ?? false : false);
    final dismissedAt = ms != null
        ? DateTime.fromMillisecondsSinceEpoch(ms)
        : (legacy ? DateTime.now() : null);
    if (dismissedAt != null && ms == null) {
      await prefs.remove(_bannerDismissedKey);
      await prefs.setInt(
          _bannerDismissedKey, dismissedAt.millisecondsSinceEpoch);
    }
    if (mounted) {
      setState(() {
        _notificationBannerDismissed = dismissedAt != null &&
            DateTime.now().difference(dismissedAt) < _dismissalWindow;
      });
    }
  }

  /// "Not now" — records the time and touches nothing else. Critically it must
  /// not reach the OS: the single iOS prompt has to survive this tap.
  Future<void> _dismissNotificationBanner() async {
    setState(() => _notificationBannerDismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _bannerDismissedKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// "Enable" — the only path in this file allowed to spend the OS prompt.
  /// One grant covers both notification types, as the card promises.
  Future<void> _enableFromPrompt() async {
    final userId = context.read<AuthProvider>().currentUser?.uid;
    if (userId == null) return;
    setState(() => _notificationBannerDismissed = true);

    final fcm = GetIt.I<IFCMService>();
    final result = await fcm.enableNotifications(userId);
    if (result == NotificationPermissionResult.granted) {
      await fcm.enableWeeklyOutlook(userId);
    }
    if (mounted) {
      await context.read<AuthProvider>().refreshUserSettings();
    }
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
        final userSettings = await GetIt.I<IUserSettingsService>()
            .getUserSettings(userId);
        if (userSettings != null && mounted) {
          setState(() {
            _selectedFlowUnit = userSettings.preferredFlowUnit.displayLabel;
          });
        }
      }
    } catch (e) {
      AppLogger.error('FavoritesPage', 'Error loading flow unit preference', e);
      // Keep default CFS if loading fails
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackPressTime != null &&
            now.difference(_lastBackPressTime!) < const Duration(seconds: 2)) {
          Navigator.of(context).pop();
          return;
        }
        _lastBackPressTime = now;
        _showExitHint();
      },
      child: CupertinoPageScaffold(
        navigationBar: _buildNavigationBar(),
        child: Stack(
          children: [
            // Banner above the list, not over it. It used to be a
            // Positioned(top: 0) in this Stack — which, despite the old
            // comment, overlaid the first favourite rather than pinning below
            // anything. In the column it takes real height and pushes the list
            // down, so nothing is ever hidden behind it.
            //
            // One SafeArea around the whole column, not one per child. The
            // scaffold's nav bar is translucent, so this child starts at y=0
            // behind it and something must clear it. Wrapping here consumes the
            // inset once and hands descendants a zeroed MediaQuery, which makes
            // the SafeArea already inside each content state a no-op — as
            // siblings they would each apply the full inset and open a gap
            // under the banner.
            SafeArea(
              top: true,
              bottom: false,
              child: Column(
                children: [
                  const SyncStatusBanner(),
                  Expanded(
                    child: Consumer<FavoritesProvider>(
                      builder: (context, favoritesProvider, child) {
                        if (favoritesProvider.isLoading) {
                          return _buildLoadingState();
                        }

                        if (favoritesProvider.isEmpty &&
                            favoritesProvider.errorMessage != null) {
                          return _buildInitErrorState(
                            favoritesProvider.errorMessage!,
                          );
                        }

                        if (favoritesProvider.isEmpty) {
                          return _buildEmptyState();
                        }

                        // ADR 0011 Phase 8 guard 2. Past every early return,
                        // so this frame is the one that actually shows rivers.
                        // The mark is one-shot; later rebuilds are ignored.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          StartupTrace.markFavouritesRendered(
                            favoritesProvider.favorites.length,
                          );
                        });

                        // Trigger Phase A coach marks when favorites are loaded
                        if (!_hasShownFavoritesTour && !_isTourActive) {
                          _maybeShowFavoritesTour(favoritesProvider);
                        }

                        return _buildFavoritesList(favoritesProvider);
                      },
                    ),
                  ),
                ],
              ),
            ),

            // Floating action button
            _buildFloatingActionButton(),
          ],
        ),
      ),
    );
  }

  CupertinoNavigationBar _buildNavigationBar() {
    return CupertinoNavigationBar(
      // "This Week" outlook entry point
      leading: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => AppRouter.pushWeeklyOutlook(context),
        child: const Icon(
          CupertinoIcons.calendar,
          semanticLabel: "This week's outlook",
        ),
      ),
      trailing: CupertinoButton(
        key: (_isTourActive || !_hasShownFavoritesTour)
            ? _settingsButtonKey
            : null,
        padding: EdgeInsets.zero,
        onPressed: _showSettingsMenu,
        child: const Icon(
          CupertinoIcons.ellipsis,
          semanticLabel: 'Settings menu',
        ),
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
                color: CupertinoColors.black.withValues(alpha: 0.2),
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
            semanticLabel: 'Add favorite river',
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 16),
      itemCount: 5,
      itemBuilder: (_, __) => const SkeletonRiverCard(),
    );
  }

  Widget _buildInitErrorState(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 48,
              color: CupertinoColors.systemRed,
              semanticLabel: 'Error',
            ),
            const SizedBox(height: 16),
            const Text(
              'Unable to Load Favorites',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: const TextStyle(
                fontSize: 14,
                color: CupertinoColors.secondaryLabel,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            CupertinoButton.filled(
              onPressed: _initializeFavorites,
              child: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return SafeArea(
      child: Column(
        children: [
          // App title header
          _buildAppHeader(),

          // Empty state content — offset upward to balance whitespace
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 32, right: 32, bottom: 100),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Empty state illustration
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemBlue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(60),
                    ),
                    child: const Icon(
                      CupertinoIcons.heart,
                      size: 60,
                      color: CupertinoColors.systemBlue,
                      semanticLabel: 'No favorites',
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
                    'Tap the + button below to explore the map and add your first river.',
                    style: TextStyle(
                      fontSize: 16,
                      color: CupertinoColors.systemGrey2..resolveFrom(context),
                      height: 1.4,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
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

                // Notification prompt banner
                Consumer<AuthProvider>(
                  builder: (context, authProvider, _) {
                    final notificationsEnabled =
                        authProvider.currentUserSettings?.enableNotifications ??
                        false;

                    // The soft ask, at the moment of expressed interest — the
                    // user has just saved their first river (ADR 0009, ph 2).
                    //
                    // Every clause is load-bearing:
                    //   first favourite  — asking before that is asking cold
                    //   notDetermined    — the prompt must still be available;
                    //                      granted needs no ask, denied cannot
                    //                      be reached by one
                    //   not dismissed    — "not now" is respected for 30 days
                    //   preference off   — nothing to ask about otherwise
                    final favs =
                        context.read<FavoritesProvider>().favorites;
                    final isFirstFavorite = favs.length == 1;
                    final canStillAsk = _osPermission ==
                        NotificationPermissionResult.notDetermined;

                    if (!notificationsEnabled &&
                        !_notificationBannerDismissed &&
                        isFirstFavorite &&
                        canStillAsk) {
                      return SliverToBoxAdapter(
                        child: NotificationPromptBanner(
                          riverName: favs.first.displayName,
                          onEnable: _enableFromPrompt,
                          onDismiss: _dismissNotificationBanner,
                        ),
                      );
                    }
                    return const SliverToBoxAdapter(child: SizedBox.shrink());
                  },
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
            ' RIVR',
            style: TextStyle(
              fontSize: 45,
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
                // Trigger Phase B search tip when search icon appears
                if (!_hasShownSearchTip && !_isTourActive) {
                  _maybeShowSearchTip(favoritesProvider);
                }
                return CupertinoButton(
                  key: (_isTourActive || !_hasShownSearchTip)
                      ? _searchIconKey
                      : null,
                  padding: EdgeInsets.zero,
                  onPressed: _toggleSearch,
                  child: Icon(
                    _showSearch
                        ? CupertinoIcons.xmark_circle_fill
                        : CupertinoIcons.search,
                    color: CupertinoColors.systemBlue,
                    semanticLabel: _showSearch
                        ? 'Close search'
                        : 'Search favorites',
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
        color: CupertinoColors.systemRed.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: CupertinoColors.systemRed.withValues(alpha: 0.3),
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
          key: index == 0 && (_isTourActive || !_hasShownFavoritesTour)
              ? _firstCardKey
              : ValueKey(favorite.reachId),
          favorite: favorite,
          cardIndex: index,
          onTap: () => _navigateToForecast(
            favorite.reachId,
            favorite.source,
            lat: favorite.latitude,
            lon: favorite.longitude,
          ),
          onRename: () => _showRenameDialog(favorite),
          isMuted: _mutedReachIds.contains(favorite.reachId),
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
            color: CupertinoColors.systemGrey.withValues(alpha: 0.5),
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
                  color: CupertinoColors.black.withValues(alpha: 0.3),
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
        final flowUnit = value == 'm³/s' ? FlowUnit.cms : FlowUnit.cfs;

        await GetIt.I<IUserSettingsService>().updateFlowUnit(userId, flowUnit);
        if (!mounted) return;
        GetIt.I<IFlowUnitPreferenceService>().setFlowUnit(
          flowUnit == FlowUnit.cms ? 'CMS' : 'CFS',
        );

        // Clear unit-dependent caches for BOTH providers
        final reachProvider = context.read<ReachDataProvider>();
        final favoritesProvider = context
            .read<FavoritesProvider>(); // ADD: Get favorites provider

        reachProvider.clearUnitDependentCaches();
        favoritesProvider.clearUnitDependentCaches();
      } else {
        // Revert UI state if no user
        if (mounted) {
          setState(() {
            _selectedFlowUnit = _selectedFlowUnit == 'ft³/s' ? 'm³/s' : 'ft³/s';
          });
        }
      }
    } catch (e) {
      // Revert UI state on error
      if (mounted) {
        setState(() {
          _selectedFlowUnit = _selectedFlowUnit == 'ft³/s' ? 'm³/s' : 'ft³/s';
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

  // Coach marks
  Future<void> _checkAndShowCoachMarks() async {
    final seenTour = await CoachMarkService.hasSeenFavoritesTour();
    final seenSearch = await CoachMarkService.hasSeenSearchTip();
    if (mounted) {
      setState(() {
        _hasShownFavoritesTour = seenTour;
        _hasShownSearchTip = seenSearch;
      });
    }
  }

  void _maybeShowFavoritesTour(FavoritesProvider provider) {
    if (_hasShownFavoritesTour || _isTourActive || provider.isEmpty) return;

    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;

    _isTourActive = true;
    _hasShownFavoritesTour = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final targets = CoachMarkTargets.buildFavoritesTourTargets(
        firstCardKey: _firstCardKey,
        settingsButtonKey: _settingsButtonKey,
      );

      TutorialCoachMark(
        targets: targets,
        colorShadow: CupertinoColors.black,
        opacityShadow: 0.9,
        hideSkip: true,
        onFinish: () {
          CoachMarkService.completeFavoritesTour();
          _isTourActive = false;
          // Check if Phase B should follow immediately
          if (!_hasShownSearchTip && provider.shouldShowSearch) {
            _maybeShowSearchTip(provider);
          } else if (mounted) {
            setState(() {});
          }
        },
        onSkip: () {
          CoachMarkService.completeFavoritesTour();
          _isTourActive = false;
          if (mounted) setState(() {});
          return true;
        },
      ).show(context: context);
    });
  }

  void _maybeShowSearchTip(FavoritesProvider provider) {
    if (_hasShownSearchTip || _isTourActive || !provider.shouldShowSearch) {
      return;
    }

    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;

    _isTourActive = true;
    _hasShownSearchTip = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final targets = CoachMarkTargets.buildSearchTipTargets(
        searchIconKey: _searchIconKey,
      );

      TutorialCoachMark(
        targets: targets,
        colorShadow: CupertinoColors.black,
        opacityShadow: 0.9,
        hideSkip: true,
        onFinish: () {
          CoachMarkService.completeSearchTip();
          _isTourActive = false;
          if (mounted) setState(() {});
        },
        onSkip: () {
          CoachMarkService.completeSearchTip();
          _isTourActive = false;
          if (mounted) setState(() {});
          return true;
        },
      ).show(context: context);
    });
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

  void _showExitHint() {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: MediaQuery.of(context).padding.bottom + 60,
        left: 0,
        right: 0,
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 200),
            builder: (context, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: CupertinoColors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Press back again to exit',
                style: TextStyle(color: CupertinoColors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () {
      entry.remove();
    });
  }

  void _showSettingsMenu() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Settings Menu',
      barrierColor: CupertinoColors.black.withValues(alpha: 0.3),
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
                    color: CupertinoColors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMenuOption(
                    'Account',
                    CupertinoIcons.person_crop_circle,
                    () {
                      Navigator.pop(context);
                      AppRouter.pushAccount(context);
                    },
                  ),
                  _buildMenuDivider(),
                  _buildMenuOption('Notifications', CupertinoIcons.bell, () {
                    Navigator.pop(context);
                    // Awaited so the muted markers refresh on return: this
                    // is where a river is most likely to be muted or unmuted.
                    AppRouter.pushNotificationsSettings(context)
                        .then((_) => _loadMutedReaches());
                  }),
                  _buildMenuDivider(),
                  _buildFlowUnitsToggleWithModalState(setModalState),
                  _buildMenuDivider(),
                  _buildMenuOption('Sponsors', CupertinoIcons.creditcard, () {
                    Navigator.pop(context);
                    AppRouter.pushSponsors(context);
                  }),
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
              'ft³/s': Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text('ft³/s', style: TextStyle(fontSize: 13)),
              ),
              'm³/s': Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text('m³/s', style: TextStyle(fontSize: 13)),
              ),
            },
          ),
          const Spacer(),
          Icon(CupertinoIcons.drop, color: CupertinoColors.white, size: 22),
        ],
      ),
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
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w400,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
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
          CupertinoColors.separator.withValues(
            alpha: 0.3,
          ), // Use provided color or default
      margin: EdgeInsets.symmetric(horizontal: 16),
    );
  }

  void _navigateToMap() {
    AppRouter.pushMap(context);
  }

  Future<void> _navigateToForecast(
    String reachId,
    ForecastSource source, {
    double? lat,
    double? lon,
  }) async {
    // Pass the favorite's coordinates so the forecast page can show a location.
    // GEOGLOWS reaches have no name/location of their own — without these, the
    // page can't reverse-geocode a place (NWM reaches carry their own coords).
    await AppRouter.pushForecast(
      context,
      reachId: reachId,
      source: source,
      lat: lat,
      lon: lon,
    );
    // The forecast page carries an alerts row, so a river can be muted or
    // unmuted while we are away. Without this the card's marker is whatever it
    // was when this page first loaded — reported on device: un-muting a river
    // left the crossed bell on its card.
    await _loadMutedReaches();
  }

  void _navigateToImageSelection(FavoriteRiver favorite) {
    AppRouter.pushImageSelection(context, reachId: favorite.reachId);
  }

  /// Publish one favourite's display label to the user document.
  ///
  /// `favoriteLabels` already existed for the weekly digest; this makes it
  /// carry the user's own name and keeps it current. The read-modify-write is
  /// deliberate — a label for a river not touched here must survive — and the
  /// key carries the SOURCE, because an NWM comid and a GEOGLOWS linkno can be
  /// numerically identical and would otherwise share one slot.
  ///
  /// Failure is logged and swallowed. The rename itself already succeeded
  /// locally, and a name that reaches the server one visit later is a far
  /// smaller problem than a rename that appears to fail.
  Future<void> _syncFavoriteLabel(FavoriteRiver favorite, String label) async {
    final userId = context.read<AuthProvider>().currentUser?.uid;
    if (userId == null || label.trim().isEmpty) return;
    try {
      final svc = GetIt.I<IUserSettingsService>();
      final settings = await svc.getUserSettings(userId);
      if (settings == null) return;

      final merged = labelsAfterRename(
        existing: settings.favoriteLabels,
        source: favorite.source,
        reachId: favorite.reachId,
        label: label,
      );
      if (merged == null) return;

      await svc.updateUserSettings(userId, {'favoriteLabels': merged});
    } catch (e) {
      AppLogger.error('FavoritesPage', 'Label sync failed: $e', e);
    }
  }

  /// Reach ids whose alerts the user has set to "Off".
  ///
  /// Read once when the page builds its list. A stale value here shows or
  /// hides a small marker for one refresh, which is a far smaller cost than
  /// listening to the settings document from a scrolling list.
  Set<String> _mutedReachIds = const {};

  Future<void> _loadMutedReaches() async {
    if (!mounted) return;
    final userId = context.read<AuthProvider>().currentUser?.uid;
    if (userId == null) return;
    try {
      // No force-refresh needed: UserSettingsService caches, but
      // updateUserSettings CLEARS that cache on every write, so a read after
      // the user changed a setting elsewhere already goes to Firestore.
      final settings =
          await GetIt.I<IUserSettingsService>().getUserSettings(userId);
      if (!mounted || settings == null) return;
      setState(() {
        _mutedReachIds = {
          for (final entry in settings.alertFrequencies.entries)
            if (entry.value == AlertFrequency.off.wireValue) entry.key,
        };
      });
    } catch (e) {
      // A marker is not worth an error state; the list is the point.
      AppLogger.error('FavoritesPage', 'Error loading muted reaches: $e', e);
    }
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
                // Push the name to the server too, so a flood alert can use
                // it. Custom names live only in device SharedPreferences, so
                // until now a notification said NOAA's official name — and
                // that name is the first thing a user reads on a lock screen.
                // Written HERE, on rename, rather than only when the Weekly
                // Outlook page is next opened: renaming a river and never
                // visiting that page meant the server never heard about it.
                await _syncFavoriteLabel(favorite, newName);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
