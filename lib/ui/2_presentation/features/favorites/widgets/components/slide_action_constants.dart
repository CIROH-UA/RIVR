// lib/ui/2_presentation/features/favorites/widgets/components/slide_action_constants.dart

/// Geometry of the actions revealed behind a favourite card.
///
/// **One number owns the reveal: [totalActionWidth].** The card is translated
/// left by exactly that many logical pixels, and the strip of buttons is
/// exactly that wide, so the card uncovers the buttons and nothing else.
///
/// It used to be expressed as a FRACTION of the screen width
/// (`getSlideOffset`) and handed to a `SlideTransition`, which multiplies by
/// the width of its own CHILD. The child is the card, and the card is 38 pt
/// narrower than the screen because of its margins — so the card travelled
/// `216 × (screenWidth − 38) / screenWidth`, which is 195 pt on a 393 pt
/// screen and 197 pt on a 440 pt one. Two things followed from that single
/// mismatch, both measured in ADR 0016: the card tracked the finger at 91%
/// for the whole drag, and it came to rest with 19-26 pt of the first button
/// still underneath it.
///
/// Pixels, not fractions. A fraction of the wrong box is how this broke.
class SlideActionConstants {
  /// One action. Three equal buttons, no overlaps.
  ///
  /// The previous strip was 95 / 90 / 80 pt wide with 12 pt overlaps, three
  /// different corner radii, icons nudged by hand (`left: 20`, `30`, `15`)
  /// and labels padded with literal spaces (`'   Delete'`) to fake their
  /// alignment. It rendered ragged and could not survive a larger text size.
  static const double buttonWidth = 72.0;

  static const int buttonCount = 3;

  /// How far the card slides, and how wide the strip behind it is.
  static const double totalActionWidth = buttonWidth * buttonCount; // 216
}
