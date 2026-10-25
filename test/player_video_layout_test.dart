import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/player/player_video_layout.dart';

/// The official feed card fills its frame (`cq3/o.java:181`, mode 4) and only
/// demotes a source whose width/height ratio reaches `landscapeRatio`
/// (`:201-226`, default 1.666 — `ShortVideoCropConfig.java:105-109`).
void main() {
  const window = Size(400, 800);
  const insets = EdgeInsets.zero;

  PlayerVideoLayout layout(Size source, {VideoFit fit = VideoFit.fillFrame}) =>
      PlayerVideoLayout.calculate(
        window: window,
        insets: insets,
        videoSize: source,
        fit: fit,
        fullScreen: true,
      );

  test('a portrait source fills the frame and keeps its ratio', () {
    final result = layout(const Size(1080, 1920));
    expect(result.video.width / result.video.height, closeTo(9 / 16, .0001));
    // Fill: at least the frame on both axes, so the caller clips the overflow.
    expect(result.video.width, greaterThanOrEqualTo(result.viewport.width));
    expect(result.video.height, greaterThanOrEqualTo(result.viewport.height));
    expect(result.video.center, result.viewport.center);
  });

  test('a wide source is pinned to the frame width instead', () {
    for (final source in [const Size(1920, 1080), const Size(1280, 720)]) {
      final result = layout(source);
      expect(
        result.video.width / result.video.height,
        closeTo(source.aspectRatio, .0001),
      );
      // Fit width: the whole picture stays inside, letterboxed vertically.
      expect(
        result.video.width,
        lessThanOrEqualTo(result.viewport.width + .01),
      );
      expect(
        result.video.height,
        lessThanOrEqualTo(result.viewport.height + .01),
      );
      expect(result.video.center, result.viewport.center);
    }
  });

  test('the 1.666 boundary decides between fill and fit width', () {
    // 官方 `cq3/o.java:204` 是 `f >= landscapeRatio` 才降级，所以恰好等于
    // 阈值时已经算横版片源，只有严格小于才继续 fill。
    expect(PlayerVideoLayout.fillsFrame(const Size(1665, 1000)), isTrue);
    expect(PlayerVideoLayout.fillsFrame(const Size(1666, 1000)), isFalse);
    expect(PlayerVideoLayout.landscapeRatio, 1.666);
    final below = layout(const Size(1665, 1000));
    expect(below.video.height, greaterThanOrEqualTo(below.viewport.height));
    final above = layout(const Size(1666, 1000));
    expect(above.video.height, lessThan(below.viewport.height));
  });

  test('an unknown source size falls back to 9:16 and still fills', () {
    final result = layout(Size.zero);
    expect(result.video.width / result.video.height, closeTo(9 / 16, .0001));
    expect(result.video.width, greaterThanOrEqualTo(result.viewport.width));
    expect(result.video.height, greaterThanOrEqualTo(result.viewport.height));
  });
  test('fit contain always keeps the picture inside', () {
    // The full page player keeps this behaviour: its panel shrinks the
    // viewport, and a filled picture would be cropped under the sheet.
    final result = layout(const Size(1080, 1920), fit: VideoFit.contain);
    expect(result.video.width, lessThanOrEqualTo(result.viewport.width + .01));
    expect(
      result.video.height,
      lessThanOrEqualTo(result.viewport.height + .01),
    );
    expect(result.video.width / result.video.height, closeTo(9 / 16, .0001));
    // A wide source fits the same way, so the two modes only differ on the
    // sources the official client fills.
    final wide = layout(const Size(1920, 1080), fit: VideoFit.contain);
    expect(wide.video.width, lessThanOrEqualTo(wide.viewport.width + .01));
    expect(wide.video.height, lessThanOrEqualTo(wide.viewport.height + .01));
  });

  test('an extreme narrow source stays finite', () {
    // A decoder is free to report something absurd; filling multiplies the
    // frame by the source ratio, so this must not produce NaN or an exception.
    final result = layout(const Size(16, 4096));
    expect(result.video.width, greaterThanOrEqualTo(result.viewport.width));
    expect(result.video.height, greaterThanOrEqualTo(result.viewport.height));
    expect(result.video.width.isFinite && result.video.height.isFinite, isTrue);
    expect(result.video.width / result.video.height, closeTo(16 / 4096, .0001));
  });

  test('an unknown size answers fill the same way in both entry points', () {
    // `calculate` lays an unknown size out as 9:16, so `fillsFrame` has to
    // agree — a caller using it to decide "clip or not" must not be told
    // otherwise during the first frames.
    expect(PlayerVideoLayout.fillsFrame(Size.zero), isTrue);
    expect(PlayerVideoLayout.sourceSize(Size.zero), const Size(9, 16));
    final result = layout(Size.zero);
    expect(result.video.width, greaterThanOrEqualTo(result.viewport.width));
  });

  test('the square source fills like any other non-wide source', () {
    final result = layout(const Size(1080, 1080));
    expect(result.video.width, closeTo(result.video.height, .0001));
    expect(result.video.height, greaterThanOrEqualTo(result.viewport.height));
  });

  test('a wide screen forces contain even when 画面撑满 is on (#59)', () {
    // 官方 `cq3/o.d()`：宽屏时强制 `DISPLAY_MODE_ASPECT_FIT`(mode 3)，所以
    // 横屏全屏里「画面撑满」不再生效。
    expect(
      PlayerVideoLayout.fitFor(fillScreen: true, fullScreen: true),
      VideoFit.contain,
    );
    expect(
      PlayerVideoLayout.fitFor(fillScreen: true, fullScreen: false),
      VideoFit.fillFrame,
    );
    expect(
      PlayerVideoLayout.fitFor(fillScreen: false, fullScreen: false),
      VideoFit.contain,
    );
  });

  test(
    'a portrait source in a landscape fullscreen keeps its whole picture',
    () {
      // 修复前会走 fillFrame：9:16 的片子被放大到铺满横屏、两轴都溢出并被裁切
      // （720P 拉大近 3 倍，画面一片糊）。修复后按 contain 居中：高度贴满、
      // 宽度留黑边，比例不变。
      final fit = PlayerVideoLayout.fitFor(fillScreen: true, fullScreen: true);
      final result = PlayerVideoLayout.calculate(
        window: const Size(800, 400),
        insets: EdgeInsets.zero,
        videoSize: const Size(1080, 1920),
        fit: fit,
        fullScreen: true,
      );
      expect(result.video.height, closeTo(result.viewport.height, .5));
      expect(result.video.width, lessThan(result.viewport.width));
      expect(result.video.width / result.video.height, closeTo(9 / 16, .0001));
      expect(result.video.center, result.viewport.center);
    },
  );

  test('a side cutout never pushes the picture off center', () {
    // 横握时摄像头/挖孔只在屏幕一侧（`insets.left` 或 `insets.right`）：
    // 画面必须按整窗居中、黑边左右等宽，否则整块画面会被推向另一侧。
    for (final insets in [
      const EdgeInsets.only(left: 44),
      const EdgeInsets.only(right: 44),
      const EdgeInsets.symmetric(horizontal: 32),
    ]) {
      final result = PlayerVideoLayout.calculate(
        window: const Size(800, 400),
        insets: insets,
        videoSize: const Size(1080, 1920),
        fit: VideoFit.contain,
        fullScreen: true,
      );
      expect(result.viewport, Offset.zero & const Size(800, 400));
      expect(result.video.center.dx, closeTo(400, .01));
      expect(
        result.video.left,
        closeTo(800 - result.video.right, .01),
        reason: '左右黑边必须等宽（insets: $insets）',
      );
    }
  });

  group('split geometry', () {
    const phone = Size(407, 904);
    const phoneInsets = EdgeInsets.only(top: 39, bottom: 16);

    test('a wide source sizes the top half by its own aspect', () {
      final height = PlayerVideoLayout.splitTopHeight(
        window: phone,
        insets: phoneInsets,
        videoSize: const Size(1920, 1080),
      );
      final available = 904 - phoneInsets.vertical;
      // 407 / (16/9) ≈ 228.9：横屏片源按宽度铺满，上半区自然高度。
      expect(height, closeTo(407 / (16 / 9), .5));
      expect(height, greaterThanOrEqualTo(available * .22));
      expect(height, lessThanOrEqualTo(available * .5));
    });

    test('a portrait source leaves at least half the height to the panel', () {
      final height = PlayerVideoLayout.splitTopHeight(
        window: phone,
        insets: phoneInsets,
        videoSize: const Size(1080, 1920),
      );
      final available = 904 - phoneInsets.vertical;
      // 竖屏片源最多 4:3 高，且不超过可用高度的 50%。
      expect(height, closeTo(available * .42, .5));
      expect(height, lessThanOrEqualTo(available * .5));
    });

    test('a short window still leaves a usable video box', () {
      final height = PlayerVideoLayout.splitTopHeight(
        window: const Size(320, 260),
        insets: EdgeInsets.zero,
        videoSize: const Size(1920, 1080),
      );
      expect(height, greaterThanOrEqualTo(96));
      expect(height, lessThanOrEqualTo(130));
    });

    test('an empty window yields no split boxes', () {
      expect(
        PlayerVideoLayout.splitTopHeight(
          window: Size.zero,
          insets: EdgeInsets.zero,
          videoSize: const Size(1920, 1080),
        ),
        0,
      );
      expect(
        PlayerVideoLayout.splitLeftWidth(
          window: Size.zero,
          insets: EdgeInsets.zero,
        ),
        0,
      );
    });

    test('left-right split keeps the panel between 32% and 45% wide', () {
      final video = PlayerVideoLayout.splitLeftWidth(
        window: const Size(900, 420),
        insets: EdgeInsets.zero,
      );
      // 900 宽：面板 38% = 342，视频 558。
      expect(video, closeTo(558, .5));
      expect(900 - video, closeTo(342, .5));

      final narrow = PlayerVideoLayout.splitLeftWidth(
        window: const Size(600, 360),
        insets: EdgeInsets.zero,
      );
      // 窄屏面板 44% = 264，视频 336。
      expect(narrow, closeTo(336, .5));
      expect(600 - narrow, closeTo(264, .5));
    });

    test('left-right split measures the window without the safe insets', () {
      final video = PlayerVideoLayout.splitLeftWidth(
        window: const Size(900, 420),
        insets: const EdgeInsets.symmetric(horizontal: 44),
      );
      // 可用宽 812，面板 38% = 308.56，视频 503.44。
      expect(video, closeTo(812 - 812 * .38, .5));
    });

    test('compact layout does not reserve the portrait chrome margins', () {
      const window = Size(407, 229);
      final compact = PlayerVideoLayout.calculate(
        window: window,
        insets: EdgeInsets.zero,
        videoSize: const Size(1920, 1080),
        fit: VideoFit.contain,
        compact: true,
      );
      final immersive = PlayerVideoLayout.calculate(
        window: window,
        insets: EdgeInsets.zero,
        videoSize: const Size(1920, 1080),
        fit: VideoFit.contain,
      );
      expect(compact.viewport, Offset.zero & window);
      // 整屏形态给信息层/运输条留 44 + 163，分屏盒子里全部还给画面。
      expect(immersive.viewport.height, lessThan(compact.viewport.height));
      expect(compact.video.height, closeTo(window.height, .5));
    });
  });
}
