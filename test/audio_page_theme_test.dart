import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/audio_page_theme.dart';

/// 听书页整页配色是从封面算出来的，不是固定色。
///
/// 官方截图 `2.jpg` 的画布 `#F3E9E8`、卡片 `#EBDDDD`、正文 `#4E2E2E` 与封面
/// `我无法收容` 同属一个暖棕色系——这组颜色只能由封面主色推出，所以取色算法
/// 本身要能挡住「透明像素」「纯灰封面」「全黑」这几种常见封面。
void main() {
  /// `count` 个同色不透明像素。
  Uint8List solid(int count, int r, int g, int b, {int a = 255}) {
    final out = Uint8List(count * 4);
    for (var i = 0; i < count; i++) {
      final o = i * 4;
      out[o] = r;
      out[o + 1] = g;
      out[o + 2] = b;
      out[o + 3] = a;
    }
    return out;
  }

  group('AudioPageTheme.dominantFromRgba', () {
    test('picks the majority bucket, not the average', () {
      // 3/4 的暖棕 + 1/4 纯白：均值会被洗成浅色，投票仍然拿到暖棕。
      final rgba = Uint8List.fromList([
        ...solid(300, 0x5A, 0x2E, 0x2E),
        ...solid(100, 0xFF, 0xFF, 0xFF),
      ]);
      final color = AudioPageTheme.dominantFromRgba(rgba);
      expect(color.r * 255, closeTo(0x5A, 2));
      expect(color.g * 255, closeTo(0x2E, 2));
      expect(color.b * 255, closeTo(0x2E, 2));
    });

    test('ignores transparent pixels', () {
      // 全透明区域不能把主色投成黑色（PNG 封面的留白就是这种形状）。
      final rgba = Uint8List.fromList([
        ...solid(100, 0, 0, 0, a: 0),
        ...solid(10, 0xC0, 0x30, 0x40),
      ]);
      final color = AudioPageTheme.dominantFromRgba(rgba);
      expect(color.r * 255, closeTo(0xC0, 2));
    });

    test('falls back when every pixel is transparent', () {
      final color = AudioPageTheme.dominantFromRgba(solid(16, 0, 0, 0, a: 0));
      expect(color, AudioPageTheme.fallback.canvas);
    });
  });

  group('AudioPageTheme.fromCover', () {
    test('a warm cover yields a light warm canvas and dark warm ink', () {
      final theme = AudioPageTheme.fromCover(const Color(0xFF5A2E2E));
      final canvas = HSLColor.fromColor(theme.canvas);
      final ink = HSLColor.fromColor(theme.ink);
      // 画布：同色相、高明度；正文：同色相、低明度。
      expect(canvas.lightness, greaterThan(0.9));
      expect(ink.lightness, lessThan(0.35));
      expect((canvas.hue - ink.hue).abs(), lessThan(30));
      expect(canvas.hue, closeTo(9, 30));
    });

    test('a grey cover keeps the official warm hue instead of going grey', () {
      final theme = AudioPageTheme.fromCover(const Color(0xFF808080));
      // 灰封面没有可用色相：饱和度被抬回可用区间，画布不会变中性灰。
      expect(HSLColor.fromColor(theme.canvas).saturation, greaterThan(0.15));
    });

    test('dark mode inverts the lightness relationship', () {
      final theme = AudioPageTheme.fromCover(
        const Color(0xFF5A2E2E),
        dark: true,
      );
      expect(HSLColor.fromColor(theme.canvas).lightness, lessThan(0.2));
      expect(HSLColor.fromColor(theme.ink).lightness, greaterThan(0.8));
    });
  });

  test('withOled only rewrites the canvas', () {
    const base = AudioPageTheme.fallback;
    expect(base.withOled(false), base);
    final oled = base.withOled(true);
    expect(oled.canvas, const Color(0xFF000000));
    expect(oled.card, base.card);
    expect(oled.ink, base.ink);
  });
}
