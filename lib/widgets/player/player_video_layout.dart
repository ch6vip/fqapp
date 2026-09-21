import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// How the picture is fitted into [PlayerVideoLayout.viewport].
///
/// The official client has one helper for both surfaces, `cq3/o`
/// (VideoViewHelper), and picks a display mode per source:
///
/// * mode 4 (`cq3/o.java:181`) fills the frame and lets the overflow be
///   cropped — the feed card's default;
/// * mode 1 (`:73-77`) pins the picture to the frame's width instead, which a
///   landscape-wide source gets (`:201-226`), and which `o.a.a` also forces for
///   a non-vertical source (`:275-346`).
enum VideoFit {
  /// Official feed-card fitting: fill the frame unless the source is
  /// landscape-wide. Needs an ancestor that clips the overflow (the card's 12dp
  /// `ClipRRect` plus the hard-edged `Stack` inside the layer).
  fillFrame,

  /// Keep the whole picture inside the frame. The full page player uses this:
  /// its panel shrinks the viewport, so filling would crop the picture under
  /// the sheet.
  contain,
}

/// All rectangles use the player's root Stack coordinates. Insets are applied
/// here once, rather than combining a SafeArea with another inset subtraction.
class PlayerVideoLayout {
  final Rect viewport;
  final Rect video;
  final double availableHeight;

  const PlayerVideoLayout._(this.viewport, this.video, this.availableHeight);

  /// Official `ShortVideoCropConfig.landscapeRatio` default
  /// (`ShortVideoCropConfig.java:105-109`). At or above this width/height ratio
  /// the client stops filling the frame and pins the picture to the frame's
  /// width instead (`cq3/o.java:201-226`, logged as 「DisplayMode@横版片源」).
  static const double landscapeRatio = 1.666;

  /// The size to lay out with: the decoder's own once it is known, otherwise
  /// the 9:16 preview the card shows its cover at.
  static Size sourceSize(Size videoSize) =>
      videoSize.width > 0 && videoSize.height > 0
      ? videoSize
      : const Size(9, 16);

  /// Whether [VideoFit.fillFrame] actually fills (and crops) for this source.
  ///
  /// A wide source is demoted to fit-width, so the whole picture — including
  /// its burnt in captions — stays visible. An unknown size resolves to 9:16
  /// through [sourceSize], exactly like [PlayerVideoLayout.calculate] does.
  static bool fillsFrame(Size videoSize) {
    final source = sourceSize(videoSize);
    return source.width / source.height < landscapeRatio;
  }

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
    required VideoFit fit,
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
    final source = sourceSize(videoSize);
    // Filling scales until both axes cover the frame, so the caller has to clip
    // the overflow; fitting keeps the whole picture inside instead.
    final scale = fit == VideoFit.fillFrame && fillsFrame(source)
        ? math.max(
            viewport.width / source.width,
            viewport.height / source.height,
          )
        : math.min(
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
