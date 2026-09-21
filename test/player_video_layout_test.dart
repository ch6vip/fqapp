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
      expect(result.video.width, lessThanOrEqualTo(result.viewport.width + .01));
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
    expect(result.video.height, lessThanOrEqualTo(result.viewport.height + .01));
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
    expect(
      result.video.width / result.video.height,
      closeTo(16 / 4096, .0001),
    );
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
}
