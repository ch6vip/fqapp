import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/audio/audio_floating_glyphs.dart';
import 'package:fqapp/widgets/reader/reader_listen_capsule.dart';

/// 阅读页听书胶囊：封面（未听书为「听」）/ 播放 / 更多 / 关闭。
void main() {
  Future<void> mount(
    WidgetTester tester, {
    required bool listening,
    bool playing = false,
    VoidCallback? onVoices,
    VoidCallback? onCover,
    VoidCallback? onToggle,
    VoidCallback? onClose,
    ReaderThemePreset preset = ReaderThemePreset.light,
    String? cover,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ReaderListenCapsule(
              listening: listening,
              playing: playing,
              preset: preset,
              cover: cover,
              onCover: onCover ?? () {},
              onToggle: onToggle ?? () {},
              onVoices: onVoices,
              onClose: onClose ?? () {},
            ),
          ),
        ),
      ),
    );
  }

  bool hasPainter<T extends CustomPainter>(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .any((paint) => paint.painter is T);

  testWidgets('尺寸与全局悬浮胶囊一致（162×50）', (tester) async {
    await mount(tester, listening: true);
    final size = tester.getSize(
      find.byKey(const ValueKey('reader-listen-capsule')),
    );
    expect(size, const Size(ReaderListenCapsule.width, 50));
    expect(ReaderListenCapsule.width, 162);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未听书时封面位置显示「听」', (tester) async {
    await mount(tester, listening: false);
    expect(find.text('听'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('在听时不显示「听」，四个区域都在', (tester) async {
    await mount(tester, listening: true, cover: null);
    expect(find.text('听'), findsNothing);
    for (final key in [
      'reader-listen-cover',
      'reader-listen-toggle',
      'reader-listen-voices',
      'reader-listen-close',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('四个区域各自只触发自己的回调', (tester) async {
    var cover = 0;
    var toggle = 0;
    var voices = 0;
    var close = 0;
    await mount(
      tester,
      listening: true,
      onCover: () => cover++,
      onToggle: () => toggle++,
      onVoices: () => voices++,
      onClose: () => close++,
    );

    for (final entry in {
      'reader-listen-cover': () => cover,
      'reader-listen-toggle': () => toggle,
      'reader-listen-voices': () => voices,
      'reader-listen-close': () => close,
    }.entries) {
      await tester.tap(find.byKey(ValueKey(entry.key)));
      await tester.pump();
      expect(entry.value(), 1, reason: '${entry.key} 应触发一次');
    }
    expect((cover, toggle, voices, close), (1, 1, 1, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未听书时⋯不可点，点了没有任何效果', (tester) async {
    var voices = 0;
    await mount(tester, listening: false, onVoices: null);
    await tester.tap(find.byKey(const ValueKey('reader-listen-voices')));
    await tester.pump();
    expect(voices, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('播放态与暂停态用不同图标', (tester) async {
    await mount(tester, listening: true, playing: true);
    expect(hasPainter<PauseGlyph>(tester), isTrue);
    expect(hasPainter<PlayGlyph>(tester), isFalse);

    await mount(tester, listening: true, playing: false);
    expect(hasPainter<PlayGlyph>(tester), isTrue);
    expect(hasPainter<PauseGlyph>(tester), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('墨水屏主题不叠半透明、不崩', (tester) async {
    await mount(tester, listening: false, preset: ReaderThemePreset.eink);
    final material = tester.widget<Material>(
      find.byKey(const ValueKey('reader-listen-capsule')),
    );
    expect(material.color, Colors.black);
    expect(find.text('听'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
