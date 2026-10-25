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

/// All rectangles use the player's root Stack coordinates. Vertical insets are
/// applied here once, rather than combining a SafeArea with another inset
/// subtraction; the picture deliberately keeps the full window width (see
/// [calculate]).
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

  /// The fit the surface should actually use.
  ///
  /// 官方 `cq3/o.d()`：wide screen 时强制 `DISPLAY_MODE_ASPECT_FIT`(mode 3)，
  /// 于是横屏全屏**永远**是居中完整显示——即使竖屏里开着「画面撑满」
  /// (`is_fill_screen`) 也一样。竖版片源在横屏里因此两侧留黑边，不会被放大
  /// 裁切（issue #59 复测：撑满带进横屏会把 720P 放大成一片糊）。
  ///
  /// Note: .agents/notes/implemented/bug-fix/2026-10-19-fullscreen-landscape-alignment.md
  static VideoFit fitFor({
    required bool fillScreen,
    required bool fullScreen,
  }) => !fillScreen || fullScreen ? VideoFit.contain : VideoFit.fillFrame;

  static double panelFractionFor(Size videoSize) =>
      videoSize.width <= 0 ||
          videoSize.height <= 0 ||
          videoSize.height > videoSize.width
      ? .55
      : .64;

  /// 上下分屏时上半区（视频盒）的高度。
  ///
  /// 横屏片源按「宽度 / 宽高比」得到自然高度（宽高比夹在 1.2–2.2，避免
  /// 超宽片源把视频压成一条）；竖屏片源最多 4:3，给下半区留出足够空间。
  /// 最终再夹到可用高度的 22%–50%，保证画面和面板都可用。
  static double splitTopHeight({
    required Size window,
    required EdgeInsets insets,
    required Size videoSize,
  }) {
    final availableWidth = math.max(0.0, window.width - insets.horizontal);
    final availableHeight = math.max(
      0.0,
      window.height - insets.top - insets.bottom,
    );
    if (availableWidth <= 0 || availableHeight <= 0) return 0;
    final source = sourceSize(videoSize);
    final aspect = source.width / source.height;
    final desired = aspect >= 1
        ? availableWidth / aspect.clamp(1.2, 2.2)
        : math.min(availableWidth * 4 / 3, availableHeight * .42);
    final minimum = math.min(
      availableHeight * .5,
      math.max(96.0, availableHeight * .22),
    );
    return desired.clamp(minimum, availableHeight * .5);
  }

  /// 左右分栏时左侧视频区的宽度。
  ///
  /// 面板至少约占 38%（窄屏 44%），最宽 360；视频区再夹在可用宽度的
  /// 45%–68%，避免小横屏里面板窄到放不下选集格子。
  static double splitLeftWidth({
    required Size window,
    required EdgeInsets insets,
  }) {
    final availableWidth = math.max(0.0, window.width - insets.horizontal);
    if (availableWidth <= 0) return 0;
    final panelFraction = availableWidth < 720 ? .44 : .38;
    final panelWidth = math.min(360.0, availableWidth * panelFraction);
    return (availableWidth - panelWidth).clamp(
      availableWidth * .45,
      availableWidth * .68,
    );
  }

  static PlayerVideoLayout calculate({
    required Size window,
    required EdgeInsets insets,
    required Size videoSize,
    required VideoFit fit,
    double panelFraction = 0,
    double? restingPanelFraction,
    bool fullScreen = false,
    bool compact = false,
  }) {
    final availableHeight = math.max(0.0, window.height - insets.top);
    final fraction = panelFraction.clamp(0.0, 1.0);
    final rest = (restingPanelFraction ?? panelFractionFor(videoSize)).clamp(
      .1,
      1.0,
    );
    final transition = (fraction / rest).clamp(0.0, 1.0);
    // compact = 分屏里的独立视频盒：盒内没有底部信息层，44/163 的边距
    // 必须跳过，否则画面会被压到盒子上半部。
    final top =
        insets.top + (fullScreen || compact ? 0 : 44) * (1 - transition);
    // Leave the episode information and transport below the picture so burnt
    // in subtitles remain visible. These margins don't jump when chrome hides.
    final bottom =
        (insets.bottom + (fullScreen || compact ? 0 : 163)) * (1 - transition) +
        availableHeight * fraction;
    // 画面按**整窗宽度**居中：横握时挖孔/摄像头那一侧只占掉控件的安全区，
    // 不能从画面里挖掉一条——否则画面会被推到另一侧、黑边一宽一窄（B站
    // 的横屏画面同样铺满整屏，只有控件让开安全区）。竖屏 left/right 恒为
    // 0，这条只在横屏带挖孔的设备上有差别。
    final viewport = Rect.fromLTWH(
      0,
      top,
      window.width,
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
