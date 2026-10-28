import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';

/// 封面下方文字块（官方 `bio.xml` 的 `fs5`/`fs6` → `AudioPlaySubtitleView`）。
///
/// 官方是 LRC 式多行滚动字幕：`setStartLine(1)` 让当前句垂直居中，上方是
/// 已读句、下方是未读句；普通行 `#66ffffff`；没有字幕数据就不占位
/// （官方没有任何正文兜底）。
void main() {
  const track = SubtitleTrack([
    SubtitleCue(startMs: 0, text: '第一句'),
    SubtitleCue(startMs: 3000, text: '第二句'),
    SubtitleCue(startMs: 6000, text: '第三句'),
  ]);

  Future<void> mount(
    WidgetTester tester, {
    required SubtitleTrack cues,
    required Duration position,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AudioInlineSubtitle(
            track: cues,
            position: position,
            onTap: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('centres the current line with context above and below',
      (tester) async {
    await mount(tester, cues: track, position: const Duration(seconds: 4));
    // 当前句由独立的 key 定位，且数据必须是正在朗读的那句。
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio-inline-subtitle-current')))
          .data,
      '第二句',
    );
    // 上一句读过了、下一句还没读，两条上下文都在位。
    expect(find.text('第一句'), findsOneWidget);
    expect(find.text('第三句'), findsOneWidget);
  });

  testWidgets('uses the official 40% white for context lines', (tester) async {
    await mount(tester, cues: track, position: const Duration(seconds: 4));
    expect(tester.widget<Text>(find.text('第一句')).style?.color,
        const Color(0x66FFFFFF));
    expect(tester.widget<Text>(find.text('第三句')).style?.color,
        const Color(0x66FFFFFF));
  });

  testWidgets('renders nothing at all without a subtitle track', (tester) async {
    await mount(tester, cues: SubtitleTrack.empty, position: Duration.zero);
    // 官方没有正文兜底：没字幕就连槽一起收起，不占位。
    expect(find.byKey(const Key('audio_inline_subtitle')), findsNothing);
    expect(find.byKey(const Key('audio-inline-subtitle-current')), findsNothing);
  });

  testWidgets('keeps the official 52dp slot and 20/24 padding', (tester) async {
    await mount(tester, cues: track, position: Duration.zero);
    final box = tester.getSize(find.byKey(const Key('audio_inline_subtitle')));
    expect(box.height, 52);
    final padding = tester.widget<Padding>(
      find
          .ancestor(
            of: find.byKey(const Key('audio_inline_subtitle')),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(padding.padding, const EdgeInsets.fromLTRB(20, 0, 20, 24));
  });
}
