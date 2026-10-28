import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/audio_page_theme.dart';
import 'package:fqapp/widgets/audio/audio_floating_player.dart';

/// 官方播放胶囊（GlobalPlayerView）的底色取自 AndroidX Palette 的色相：
/// muted → lightMuted → darkMuted → vibrant → darkVibrant → dominant。
/// 这里用合成像素验证 swatch 的选择顺序，不依赖任何图片文件。
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

  /// 像素经 Palette 的 5 bit 量化后颜色不变，可直接用原色算期望色相。
  double hslHue(int r, int g, int b) =>
      HSLColor.fromColor(Color.fromARGB(255, r, g, b)).hue;

  group('AudioPageTheme.paletteHueFromRgba', () {
    test('a muted-dominated cover picks the muted swatch hue', () {
      // #408060：饱和度 0.33、明度 0.38，落在 muted 目标区间。
      // #00FF80：饱和度 1、明度 0.49，会被 vibrant 先挑走。
      final rgba = Uint8List.fromList([
        ...solid(70, 0x40, 0x80, 0x60),
        ...solid(30, 0x00, 0xFF, 0x80),
      ]);
      final hue = AudioPageTheme.paletteHueFromRgba(rgba);
      expect(hue, isNotNull);
      expect(hue, closeTo(hslHue(0x40, 0x80, 0x60), 0.01));
    });

    test('without any muted swatch the chain falls through to vibrant', () {
      // 没有 muted 候选：vibrant 取走 #00F880，暗红只配 darkVibrant。
      // 暗红人口更多（是 dominant），若误用 dominant 会得到色相 0。
      final rgba = Uint8List.fromList([
        ...solid(60, 0x80, 0x00, 0x00),
        ...solid(40, 0x00, 0xFF, 0x80),
      ]);
      final hue = AudioPageTheme.paletteHueFromRgba(rgba);
      expect(hue, closeTo(hslHue(0x00, 0xF8, 0x80), 0.5));
      expect(hue, isNot(closeTo(hslHue(0x80, 0x00, 0x00), 1)));
    });

    test('a single-colour cover returns the dominant hue', () {
      final hue = AudioPageTheme.paletteHueFromRgba(
        solid(100, 0x40, 0x80, 0x60),
      );
      expect(hue, closeTo(hslHue(0x40, 0x80, 0x60), 0.01));
    });

    test('a fully transparent cover has no swatch', () {
      final rgba = solid(16, 0, 0, 0, a: 0);
      expect(AudioPageTheme.paletteHueFromRgba(rgba), isNull);
    });
  });

  testWidgets('the capsule background crossfades instead of jumping', (
    tester,
  ) async {
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);

    Widget app(Brightness brightness) => MaterialApp(
      // 关掉 MaterialApp 自己的主题过渡，否则前 200ms 读到的还是旧 brightness。
      themeAnimationDuration: Duration.zero,
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: Stack(
          children: [
            AudioFloatingPlayer(
              title: 't',
              cover: '',
              position: position,
              duration: const Duration(seconds: 1),
              playing: false,
              loading: false,
              canToggle: false,
              visible: true,
              bottomInset: 0,
              onOpen: () {},
              onToggle: () {},
              onClose: () {},
            ),
          ],
        ),
      ),
    );

    // 胶囊自己的 Material 是唯一不透明的 Material；IconButton 内部的是
    // 透明的 InkWell 载体，过滤掉。
    Color background() {
      final colors = tester
          .widgetList<Material>(
            find.descendant(
              of: find.byType(AudioFloatingPlayer),
              matching: find.byType(Material),
            ),
          )
          .map((material) => material.color)
          .whereType<Color>()
          .where((color) => color.a > 0.5);
      expect(colors, hasLength(1));
      return colors.single;
    }

    await tester.pumpWidget(app(Brightness.dark));
    await tester.pump();
    expect(background(), const Color(0xFB4A4A4A));

    // 切到浅色后底色应从 0xFB4A4A4A 平滑过渡到兜底 0xFC666666，
    // 而不是一帧跳变。
    await tester.pumpWidget(app(Brightness.light));
    // 第一帧只用来给 ticker 记起点，之后再推时间才能看到中间色。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final mid = background();
    expect(mid, isNot(const Color(0xFB4A4A4A)));
    expect(mid, isNot(const Color(0xFC666666)));

    await tester.pump(const Duration(milliseconds: 200));
    expect(background(), const Color(0xFC666666));
  });
}
