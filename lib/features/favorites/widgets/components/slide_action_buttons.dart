// lib/features/favorites/widgets/components/slide_action_buttons.dart

import 'package:flutter/cupertino.dart';
import '../../../../core/models/favorite_river.dart';
import '../../../../core/providers/favorites_provider.dart';
import 'slide_action_constants.dart';

class SlideActionButtons extends StatelessWidget {
  final FavoriteRiver favorite;
  final VoidCallback? onChangeImage;
  final VoidCallback? onRename;
  final VoidCallback onCloseSlide;
  final FavoritesProvider favoritesProvider;

  const SlideActionButtons({
    super.key,
    required this.favorite,
    required this.onCloseSlide,
    required this.favoritesProvider,
    this.onChangeImage,
    this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120, // Match the card height
      child: _buildOverlappingButtons(context),
    );
  }

  Widget _buildOverlappingButtons(BuildContext context) {
    return SizedBox(
      width: SlideActionConstants.totalActionWidth,
      height: double.infinity,
      child: Stack(
        clipBehavior:
            Clip.none, // Allow buttons to extend beyond bounds if needed
        children: [
          // Delete button (bottom layer - rightmost)
          Positioned(
            left:
                SlideActionConstants.totalActionWidth -
                SlideActionConstants.buttonWidth, // Rightmost position
            top: 0,
            child: _buildActionButton(
              width: SlideActionConstants.buttonWidth,
              color: CupertinoColors.systemRed,
              icon: CupertinoIcons.trash,
              iconPadding: const EdgeInsets.only(left: 20),
              label: '   Delete',
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(12),
                bottomRight: Radius.circular(12),
                topLeft: Radius.circular(6),
                bottomLeft: Radius.circular(6),
              ),
              onPressed: () => _handleDelete(context),
            ),
          ),

          // Rename button (middle layer)
          Positioned(
            left:
                SlideActionConstants.buttonWidth -
                SlideActionConstants.overlap, // Middle position
            top: 0,
            child: _buildActionButton(
              width: SlideActionConstants.buttonWidth + 10,
              color: CupertinoColors.systemOrange,
              icon: CupertinoIcons.pencil_ellipsis_rectangle,
              iconPadding: const EdgeInsets.only(left: 30),
              label: '     Rename',
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
              onPressed: () {
                onCloseSlide();
                onRename?.call();
              },
            ),
          ),

          // Image button (top layer - leftmost, appears on top)
          Positioned(
            left: 0, // Leftmost position
            top: 0,
            child: _buildActionButton(
              width: SlideActionConstants.buttonWidth + 15,
              color: CupertinoColors.systemBlue,
              icon: CupertinoIcons.photo,
              iconPadding: const EdgeInsets.only(left: 15),
              label: '  Background',
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
              onPressed: () {
                onCloseSlide();
                onChangeImage?.call();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required double width,
    required Color color,
    required IconData icon,
    required String label,
    required BorderRadius borderRadius,
    required VoidCallback onPressed,
    EdgeInsets iconPadding = const EdgeInsets.only(
      left: 15.0,
    ), // Add this parameter
  }) {
    return SizedBox(
      width: width,
      height: 120,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Container(
          width: width,
          height: double.infinity,
          decoration: BoxDecoration(
            color: color,
            borderRadius: borderRadius,
            boxShadow: [
              BoxShadow(
                color: CupertinoColors.black.withOpacity(0.1),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: iconPadding, // Use the parameter
                child: Icon(icon, color: CupertinoColors.white, size: 22),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 12.0),
                child: Text(
                  label,
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleDelete(BuildContext context) {
    onCloseSlide();
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Remove Favorite'),
        content: Text('Remove "${favorite.displayName}" from your favorites?'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () async {
              Navigator.pop(context);
              await favoritesProvider.removeFavorite(favorite.reachId);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}
