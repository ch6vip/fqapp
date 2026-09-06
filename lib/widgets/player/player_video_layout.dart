import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// All rectangles use the player's root Stack coordinates. Insets are applied
/// here once, rather than combining a SafeArea with another inset subtraction.
class PlayerVideoLayout {
  final Rect viewport;
  final Rect video;
  final double availableHeight;

  const PlayerVideoLayout._(this.viewport, this.video, this.availableHeight);

  static double panelFractionFor(Size videoSize) =>
      videoSize.width <= 0 ||
          videoSize.height <= 0 ||
          videoSize.height > videoSize.width
      ? .55
      : .64;

  static PlayerVideoLayout calculate({
    required Size window,
    required EdgeInsets insets,
    required Size videoSize,
    double panelFraction = 0,
    double? restingPanelFraction,
    bool fullScreen = false,
  }) {
    final availableHeight = math.max(0.0, window.height - insets.top);
    final fraction = panelFraction.clamp(0.0, 1.0);
    final rest = (restingPanelFraction ?? panelFractionFor(videoSize)).clamp(
      .1,
      1.0,
    );
    final transition = (fraction / rest).clamp(0.0, 1.0);
    final top = insets.top + (fullScreen ? 0 : 44) * (1 - transition);
    // Leave the episode information and transport below the picture so burnt
    // in subtitles remain visible. These margins don't jump when chrome hides.
    final bottom =
        (insets.bottom + (fullScreen ? 0 : 163)) * (1 - transition) +
        availableHeight * fraction;
    final viewport = Rect.fromLTWH(
      insets.left,
      top,
      math.max(0.0, window.width - insets.horizontal),
      math.max(0.0, window.height - top - bottom),
    );
    final source = videoSize.width > 0 && videoSize.height > 0
        ? videoSize
        : const Size(9, 16);
    final scale = math.min(
      viewport.width / source.width,
      viewport.height / source.height,
    );
    final size = Size(source.width * scale, source.height * scale);
    return PlayerVideoLayout._(
      viewport,
      Rect.fromCenter(
        center: viewport.center,
        width: size.width,
        height: size.height,
      ),
      availableHeight,
    );
  }
}
