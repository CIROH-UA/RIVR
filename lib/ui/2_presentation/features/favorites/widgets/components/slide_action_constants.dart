// lib/ui/2_presentation/features/favorites/widgets/components/slide_action_constants.dart

class SlideActionConstants {
  // Button dimensions
  static const double buttonWidth = 80.0;
  static const double overlap = 12.0;

  // Calculated total width of action buttons
  static const double totalActionWidth =
      (buttonWidth * 3) - (overlap * 2); // 156px

  // Calculate slide offset based on screen width
  static double getSlideOffset(double screenWidth) {
    // We want to slide left by exactly the width of the action buttons
    // Convert to percentage: negative because sliding left
    return -(totalActionWidth / screenWidth);
  }

  // Alternative: if you want a small margin between card and buttons
  static double getSlideOffsetWithMargin(
    double screenWidth, {
    double margin = 8.0,
  }) {
    return -((totalActionWidth + margin) / screenWidth);
  }
}
