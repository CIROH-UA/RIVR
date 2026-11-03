// lib/ui/2_presentation/features/favorites/widgets/components/slide_action_buttons.dart

import 'package:flutter/cupertino.dart';
import 'package:rivr/models/1_domain/shared/favorite_river.dart';
import 'package:rivr/ui/1_state/features/favorites/favorites_provider.dart';
import 'package:rivr/ui/2_presentation/features/favorites/widgets/components/slide_action_constants.dart';

/// The three actions revealed when a favourite card is swiped left.
///
/// Rewritten 2026-11-02 (ADR 0016). The previous version stacked three
/// different widths with 12 pt overlaps, gave each a different set of corner
/// radii, nudged every icon with its own left padding and faked the label
/// alignment with literal leading spaces. Equal widths in a row need none of
/// that, survive a larger text size, and read as one control instead of three
/// pasted-on rectangles.
class SlideActionButtons extends StatelessWidget {
  final FavoriteRiver favorite;
  final VoidCallback? onChangeImage;
  final VoidCallback? onRename;
  final VoidCallback onCloseSlide;
  final FavoritesProvider favoritesProvider;

  /// Matches the card it sits behind.
  static const double height = 120.0;
  static const double _cardRadius = 12.0;

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
      width: SlideActionConstants.totalActionWidth,
      height: height,
      child: Row(
        children: [
          _action(
            color: CupertinoColors.systemBlue,
            icon: CupertinoIcons.photo,
            label: 'Background',
            onPressed: () {
              onCloseSlide();
              onChangeImage?.call();
            },
          ),
          _action(
            color: CupertinoColors.systemOrange,
            icon: CupertinoIcons.pencil,
            label: 'Rename',
            onPressed: () {
              onCloseSlide();
              onRename?.call();
            },
          ),
          _action(
            color: CupertinoColors.systemRed,
            icon: CupertinoIcons.trash,
            label: 'Delete',
            // Only the outer edge is rounded — the other two butt against
            // their neighbours, and the left edge is uncovered by the card.
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(_cardRadius),
              bottomRight: Radius.circular(_cardRadius),
            ),
            onPressed: () => _handleDelete(context),
          ),
        ],
      ),
    );
  }

  Widget _action({
    required Color color,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    BorderRadius borderRadius = BorderRadius.zero,
  }) {
    return SizedBox(
      width: SlideActionConstants.buttonWidth,
      height: height,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Container(
          decoration: BoxDecoration(color: color, borderRadius: borderRadius),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The label already says this; a semantic label on the icon
              // would make VoiceOver read the action twice.
              ExcludeSemantics(
                child: Icon(icon, color: CupertinoColors.white, size: 22),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
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
        // The button says Delete, so the dialog says Delete. It used to open
        // "Remove Favorite" with a "Remove" action — one action, two verbs.
        title: const Text('Delete Favorite'),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
