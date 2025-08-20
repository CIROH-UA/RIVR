// lib/features/forecast/utils/flow_category_pulse_animator.dart

import 'package:flutter/cupertino.dart';

/// Utility class to manage category-based pulse animations for flow status cards
///
/// Usage:
/// ```dart
/// final animator = FlowCategoryPulseAnimator(vsync: this);
/// animator.updateCategory('major');
/// // In build method: animator.animation.value
/// ```
class FlowCategoryPulseAnimator {
  final TickerProvider vsync;

  AnimationController? _controller;
  Animation<double>? _animation;
  String _currentCategory = 'normal';
  bool _isEnabled = true;

  FlowCategoryPulseAnimator({required this.vsync}) {
    _initializeAnimation(_currentCategory);
  }

  /// Get current animation for use in AnimatedBuilder
  Animation<double>? get animation => _animation;

  /// Get current animation value (for direct use)
  double get value => _animation?.value ?? 1.0;

  /// Check if animation is currently running
  bool get isAnimating => _controller?.isAnimating ?? false;

  /// Update animation based on flow category
  void updateCategory(String category, {bool forceUpdate = false}) {
    final normalizedCategory = category.toLowerCase();

    if (_currentCategory != normalizedCategory || forceUpdate) {
      _currentCategory = normalizedCategory;
      _initializeAnimation(normalizedCategory);
    }
  }

  /// Enable or disable animations (useful for accessibility)
  void setEnabled(bool enabled) {
    if (_isEnabled != enabled) {
      _isEnabled = enabled;

      if (!enabled) {
        _controller?.stop();
        _controller?.reset();
      } else {
        _controller?.repeat(reverse: true);
      }
    }
  }

  /// Start the pulse animation
  void start() {
    if (_isEnabled && _controller != null) {
      _controller!.repeat(reverse: true);
    }
  }

  /// Stop the pulse animation
  void stop() {
    _controller?.stop();
  }

  /// Reset animation to initial state
  void reset() {
    _controller?.reset();
  }

  /// Initialize animation with category-specific parameters
  void _initializeAnimation(String category) {
    // Dispose existing controller
    _controller?.dispose();

    final config = _getAnimationConfigForCategory(category);

    _controller = AnimationController(duration: config.duration, vsync: vsync);

    _animation = Tween<double>(
      begin: config.scaleMin,
      end: config.scaleMax,
    ).animate(CurvedAnimation(parent: _controller!, curve: config.curve));

    // Start animation if enabled
    if (_isEnabled) {
      start();
    }
  }

  /// Get animation configuration for each flow category
  _FlowAnimationConfig _getAnimationConfigForCategory(String category) {
    switch (category) {
      case 'normal':
        return const _FlowAnimationConfig(
          duration: Duration(milliseconds: 3000),
          scaleMin: 0.98,
          scaleMax: 1.0,
          curve: Curves.easeInOut,
        );

      case 'action':
        return const _FlowAnimationConfig(
          duration: Duration(milliseconds: 2500),
          scaleMin: 0.96,
          scaleMax: 1.02,
          curve: Curves.easeInOut,
        );

      case 'moderate':
        return const _FlowAnimationConfig(
          duration: Duration(milliseconds: 2000),
          scaleMin: 0.94,
          scaleMax: 1.04,
          curve: Curves.elasticInOut,
        );

      case 'major':
        return const _FlowAnimationConfig(
          duration: Duration(milliseconds: 1500),
          scaleMin: 0.92,
          scaleMax: 1.06,
          curve: Curves.bounceInOut,
        );

      case 'extreme':
        return const _FlowAnimationConfig(
          duration: Duration(milliseconds: 1000),
          scaleMin: 0.90,
          scaleMax: 1.08,
          curve: Curves.elasticInOut,
        );

      case 'unknown':
      default:
        return const _FlowAnimationConfig(
          duration: Duration(milliseconds: 4000),
          scaleMin: 0.99,
          scaleMax: 1.0,
          curve: Curves.linear,
        );
    }
  }

  /// Dispose of animation resources
  void dispose() {
    _controller?.dispose();
    _controller = null;
    _animation = null;
  }
}

/// Configuration data class for flow category animations
class _FlowAnimationConfig {
  final Duration duration;
  final double scaleMin;
  final double scaleMax;
  final Curve curve;

  const _FlowAnimationConfig({
    required this.duration,
    required this.scaleMin,
    required this.scaleMax,
    required this.curve,
  });
}

/// Optional: Enhanced pulse animator with color effects
class FlowCategoryPulseAnimatorEnhanced extends FlowCategoryPulseAnimator {
  Animation<Color?>? _colorAnimation;

  FlowCategoryPulseAnimatorEnhanced({required super.vsync});

  /// Get color pulse animation (optional feature)
  Animation<Color?>? get colorAnimation => _colorAnimation;

  @override
  void _initializeAnimation(String category) {
    super._initializeAnimation(category);

    // Add color pulse for higher risk categories
    if (_shouldHaveColorPulse(category)) {
      _colorAnimation = _createColorPulseAnimation(category);
    } else {
      _colorAnimation = null;
    }
  }

  /// Determine if category should have color pulse effect
  bool _shouldHaveColorPulse(String category) {
    return ['moderate', 'major', 'extreme'].contains(category);
  }

  /// Create color pulse animation for enhanced visual feedback
  Animation<Color?> _createColorPulseAnimation(String category) {
    Color pulseColor;

    switch (category) {
      case 'moderate':
        pulseColor = CupertinoColors.systemOrange.withOpacity(0.1);
        break;
      case 'major':
        pulseColor = CupertinoColors.systemRed.withOpacity(0.15);
        break;
      case 'extreme':
        pulseColor = CupertinoColors.systemPurple.withOpacity(0.2);
        break;
      default:
        pulseColor = CupertinoColors.systemGrey.withOpacity(0.05);
    }

    return ColorTween(
      begin: CupertinoColors.systemBackground.withOpacity(0),
      end: pulseColor,
    ).animate(_controller!);
  }

  @override
  void dispose() {
    _colorAnimation = null;
    super.dispose();
  }
}
