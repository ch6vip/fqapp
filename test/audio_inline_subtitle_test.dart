import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/services/audio_page_theme.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';
import 'package:fqapp/widgets/audio/audio_subtitle_scroller.dart';

/// 封面下方文字块（官方 `bio.xml` 的 `fs5`/`fs6` → `AudioPlaySubtitleView`）。
///
/// 官方取证结论（`header/m0` + `subtitle/AudioPlaySubtitleView`）：
/// * 高度按字号取档再减 2dp（16sp ⇒ 50dp）；
/// * `b2.k` 内联条目上下各 3dp，按显示行分配时间；
/// * `m0.h0/i0` 普通行使用主题主文字色的 40%；
/// * 槽位常驻，无数据时显示状态文案；只有 NOT_SUPPORT 才整块收起；
/// * 换句动画是余弦 `AccelerateDecelerateInterpolator`，时长 clamp(|Δ|,300,600)。
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
    bool supported = true,
    Duration duration = const Duration(seconds: 26),
    double width = 393,
    double fontSize = 16,
    double scale = 1,
    AudioPageTheme theme = AudioPageTheme.fallback,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: AudioPageThemeScope(
          theme: theme,
          child: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              // 固定成手机宽度：测试默认视口 800 太宽，长句不会换行。
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: AudioInlineSubtitle(
                    track: cues,
                    position: position,
                    duration: duration,
                    fontSize: fontSize,
                    onTap: () {},
                    supported: supported,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('pins the current line below the 3dp inline top padding', (
    tester,
  ) async {
    await mount(tester, cues: track, position: const Duration(seconds: 4));
    final current = find.byKey(const Key('audio-inline-subtitle-current'));
    expect(tester.widget<Text>(current).data, '第二句');
    final slotTop = tester.getTopLeft(
      find.byKey(const Key('audio_inline_subtitle')),
    );
    final lineTop = tester.getTopLeft(current);
    expect(lineTop.dy - slotTop.dy, closeTo(3, 0.6));
  });

  testWidgets('keeps already-read lines above the viewport', (tester) async {
    await mount(tester, cues: track, position: const Duration(seconds: 4));
    final slotTop = tester.getTopLeft(
      find.byKey(const Key('audio_inline_subtitle')),
    );
    // 上一句在 `v(i) - c < 0` 处，被 ClipRect 裁到视口外（官方不居中）。
    final previous = tester.getTopLeft(find.text('第一句'));
    expect(previous.dy, lessThan(slotTop.dy));
  });

  testWidgets('splits a long cue into independently timed display lines', (
    tester,
  ) async {
    const long = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '一一一一一一一一一一一一一一一一一一一一一二二二二二'),
    ]);
    await mount(tester, cues: long, position: const Duration(seconds: 1));
    final current = find.byKey(const Key('audio-inline-subtitle-current'));
    final size = tester.getSize(current);
    expect(tester.widget<Text>(current).data, '一' * 21);
    expect(size.height, lessThan(30));
    final next = find.text('二' * 5);
    expect(next, findsOneWidget);
    expect(
      tester.widget<Text>(next).style?.color,
      AudioPageTheme.fallback.ink.withValues(alpha: 0.4),
    );
    expect(
      tester.getTopLeft(next).dy - tester.getBottomLeft(current).dy,
      closeTo(6, 0.6),
    );
    final slotTop = tester.getTopLeft(
      find.byKey(const Key('audio_inline_subtitle')),
    );
    expect(tester.getTopLeft(current).dy - slotTop.dy, closeTo(3, 0.6));
    await mount(tester, cues: long, position: const Duration(seconds: 22));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(current).data, '二' * 5);
    expect(tester.getTopLeft(current).dy - slotTop.dy, closeTo(3, 0.6));
  });

  testWidgets('uses 40% theme ink for context without fading current text', (
    tester,
  ) async {
    await mount(tester, cues: track, position: const Duration(seconds: 4));
    expect(
      tester.widget<Text>(find.text('第一句')).style?.color,
      AudioPageTheme.fallback.ink.withValues(alpha: 0.4),
    );
    expect(
      tester.widget<Text>(find.text('第三句')).style?.color,
      AudioPageTheme.fallback.ink.withValues(alpha: 0.4),
    );
    // 当前行不加粗（官方只 setTypeface(DEFAULT)）。
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio-inline-subtitle-current')))
          .style
          ?.fontWeight,
      isNot(FontWeight.w600),
    );
    expect(
      find.ancestor(
        of: find.byKey(const Key('audio-inline-subtitle-current')),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );
    await mount(
      tester,
      cues: track,
      position: const Duration(seconds: 4),
      theme: AudioPageTheme.fallbackDark,
    );
    expect(
      tester.widget<Text>(find.text('第三句')).style?.color,
      AudioPageTheme.fallbackDark.ink.withValues(alpha: 0.4),
    );
  });

  testWidgets('keeps the slot with a status text when the track is empty', (
    tester,
  ) async {
    await mount(tester, cues: SubtitleTrack.empty, position: Duration.zero);
    // 官方 LOADING/ERROR 走 setStatusText，槽位仍在。
    expect(find.byKey(const Key('audio_inline_subtitle')), findsOneWidget);
    expect(
      find.byKey(const Key('audio-inline-subtitle-status')),
      findsOneWidget,
    );
    expect(find.text('本章暂无同步字幕'), findsOneWidget);
  });

  testWidgets('collapses only when subtitles are not supported', (
    tester,
  ) async {
    await mount(
      tester,
      cues: SubtitleTrack.empty,
      position: Duration.zero,
      supported: false,
    );
    // 官方 NOT_SUPPORT ⇒ UIKt.gone(view)。
    expect(find.byKey(const Key('audio_inline_subtitle')), findsNothing);
  });

  testWidgets('uses the official 50dp slot and 20/24 padding', (tester) async {
    await mount(tester, cues: track, position: Duration.zero);
    expect(
      tester.getSize(find.byKey(const Key('audio_inline_subtitle'))).height,
      50,
    );
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

  testWidgets('seeking before the first cue resets the offset', (tester) async {
    const delayed = SubtitleTrack([
      SubtitleCue(startMs: 1000, text: 'first'),
      SubtitleCue(startMs: 3000, text: 'second'),
    ]);
    await mount(tester, cues: delayed, position: const Duration(seconds: 4));
    await mount(tester, cues: delayed, position: Duration.zero);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('audio-inline-subtitle-current')),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.text('first')).dy -
          tester.getTopLeft(find.byKey(const Key('audio_inline_subtitle'))).dy,
      closeTo(3, 0.6),
    );
  });

  testWidgets('retargets a paused seek during a scroll animation', (
    tester,
  ) async {
    await mount(tester, cues: track, position: Duration.zero);
    await mount(tester, cues: track, position: const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 100));
    await mount(tester, cues: track, position: const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('第三句')).dy -
          tester.getTopLeft(find.byKey(const Key('audio_inline_subtitle'))).dy,
      closeTo(3, 0.6),
    );
    await mount(tester, cues: track, position: Duration.zero);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio-inline-subtitle-current')))
          .data,
      '第一句',
    );
  });

  testWidgets('remeasures row heights and slot when text scaling changes', (
    tester,
  ) async {
    await mount(tester, cues: track, position: Duration.zero);
    final before = tester.getSize(find.text('第一句')).height;
    await mount(tester, cues: track, position: Duration.zero, scale: 2);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text('第一句')).height, closeTo(before * 2, 0.6));
    expect(
      tester.getSize(find.byKey(const Key('audio_inline_subtitle'))).height,
      100,
    );
    expect(
      tester.getTopLeft(find.text('第二句')).dy -
          tester.getBottomLeft(find.text('第一句')).dy,
      closeTo(6, 0.6),
    );
  });

  testWidgets(
    'reflows equal-count replacement tracks and font or width changes',
    (tester) async {
      final current = find.byKey(const Key('audio-inline-subtitle-current'));
      await mount(tester, cues: track, position: Duration.zero);
      final replacement = SubtitleTrack([
        SubtitleCue(startMs: 0, text: '长' * 40),
        const SubtitleCue(startMs: 4000, text: '后续'),
        const SubtitleCue(startMs: 8000, text: '末尾'),
      ]);
      await mount(tester, cues: replacement, position: Duration.zero);
      expect(tester.widget<Text>(current).data, '长' * 21);
      await mount(
        tester,
        cues: replacement,
        position: Duration.zero,
        width: 240,
      );
      expect(tester.widget<Text>(current).data!.length, lessThan(21));
      final before = tester.widget<Text>(current).data!.length;
      await mount(
        tester,
        cues: replacement,
        position: Duration.zero,
        width: 240,
        fontSize: 24,
      );
      expect(tester.widget<Text>(current).data!.length, lessThan(before));
      expect(
        tester.getSize(find.byKey(const Key('audio_inline_subtitle'))).height,
        72,
      );
    },
  );

  testWidgets('handles empty transitions during animation without stale rows', (
    tester,
  ) async {
    await mount(tester, cues: track, position: Duration.zero);
    await mount(tester, cues: track, position: const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 100));
    await mount(tester, cues: SubtitleTrack.empty, position: Duration.zero);
    await tester.pumpAndSettle();
    expect(find.text('第一句'), findsNothing);
    expect(
      find.ancestor(
        of: find.byKey(const Key('audio-inline-subtitle-status')),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );
    await mount(tester, cues: track, position: const Duration(seconds: 6));
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio-inline-subtitle-current')))
          .data,
      '第三句',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds only nearby rows of a long chapter', (tester) async {
    final long = SubtitleTrack([
      for (var i = 0; i < 1000; i++)
        SubtitleCue(startMs: i * 1000, text: 'row $i'),
    ]);
    await mount(tester, cues: long, position: const Duration(seconds: 800));
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio-inline-subtitle-current')))
          .data,
      'row 800',
    );
    final rows = find.descendant(
      of: find.byType(AudioSubtitleScroller),
      matching: find.byType(Text),
    );
    expect(rows.evaluate().length, lessThan(6));
  });

  testWidgets('manuscript retains unsplit cues and its starting line', (
    tester,
  ) async {
    final long = SubtitleTrack([SubtitleCue(startMs: 0, text: '文稿' * 30)]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 400,
            child: AudioSubtitleScroller(
              track: long,
              position: Duration.zero,
              viewportHeight: 400,
              startLine: 3,
            ),
          ),
        ),
      ),
    );
    expect(find.text('文稿' * 30), findsOneWidget);
    expect(tester.getSize(find.text('文稿' * 30)).height, greaterThan(40));
  });

  group('official scroll animation', () {
    test('duration is clamp(|Δpx|, 300, 600) ms', () {
      expect(AudioSubtitleScroller.animationFor(10).inMilliseconds, 300);
      expect(AudioSubtitleScroller.animationFor(450).inMilliseconds, 450);
      expect(AudioSubtitleScroller.animationFor(-900).inMilliseconds, 600);
    });

    test('curve is cosine ease-in-out, not linear', () {
      const curve = AudioSubtitleScroller.officialCurve;
      expect(curve.transform(0), 0);
      expect(curve.transform(0.5), closeTo(0.5, 1e-9));
      expect(curve.transform(1), 1);
      // AccelerateDecelerateInterpolator 在 t=0.25 处约为 0.1464；线性会是 0.25。
      expect(curve.transform(0.25), closeTo(0.1464, 0.002));
    });
  });
}
