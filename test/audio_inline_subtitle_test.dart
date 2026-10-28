import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';
import 'package:fqapp/widgets/audio/audio_subtitle_scroller.dart';

/// 封面下方文字块（官方 `bio.xml` 的 `fs5`/`fs6` → `AudioPlaySubtitleView`）。
///
/// 官方取证结论（`header/m0` + `subtitle/AudioPlaySubtitleView`）：
/// * 高度按字号取档再减 2dp（16sp ⇒ 50dp）；
/// * 当前句**行顶贴视口 10dp**，`startLine=1` 使 `base=0`，官方没有居中公式；
/// * 普通行 `#66ffffff`；
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
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 固定成手机宽度：测试默认视口 800 太宽，长句不会换行。
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 393,
              child: AudioInlineSubtitle(
                track: cues,
                position: position,
                onTap: () {},
                supported: supported,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('pins the current line at the very top of the slot',
      (tester) async {
    await mount(tester, cues: track, position: const Duration(seconds: 4));
    final current = find.byKey(const Key('audio-inline-subtitle-current'));
    expect(tester.widget<Text>(current).data, '第二句');
    final slotTop = tester.getTopLeft(
      find.byKey(const Key('audio_inline_subtitle')),
    );
    final lineTop = tester.getTopLeft(current);
    // 官方 `y = base(0) + v(j) + m(j) - c`，且 `m(j)=0`、`c = v(j)`
    // ⇒ 当前句方块顶正好落在视口 0。
    expect(lineTop.dy - slotTop.dy, closeTo(0, 0.6));
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

  testWidgets('lets a long cue wrap instead of ellipsizing it', (tester) async {
    // 官方截图（2.jpg）里封面卡下方是**一条换行成两行的长句**，
    // 行间没有额外间距，且从带顶开始排——不是单行加省略号。
    const long = SubtitleTrack([
      SubtitleCue(
        startMs: 0,
        text: '从坟地里挖出了一具尸体出来，还是真的击杀了一只相位翼龙',
      ),
    ]);
    await mount(tester, cues: long, position: const Duration(seconds: 1));
    final current = find.byKey(const Key('audio-inline-subtitle-current'));
    final size = tester.getSize(current);
    // 两行 16sp 文本的高度约 38dp；单行只有约 19dp。
    expect(size.height, greaterThan(30));
    // 从带顶起排（官方 `y = base + v(j) + m(j) - c`，三者相消后为 0）。
    final slotTop = tester.getTopLeft(
      find.byKey(const Key('audio_inline_subtitle')),
    );
    expect(tester.getTopLeft(current).dy - slotTop.dy, closeTo(0, 0.6));
  });

  testWidgets('uses the official 40% white for context lines', (tester) async {
    await mount(tester, cues: track, position: const Duration(seconds: 4));
    expect(
      tester.widget<Text>(find.text('第一句')).style?.color,
      AudioSubtitleScroller.contextInk,
    );
    expect(
      tester.widget<Text>(find.text('第三句')).style?.color,
      AudioSubtitleScroller.contextInk,
    );
    // 当前行不加粗（官方只 setTypeface(DEFAULT)）。
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio-inline-subtitle-current')))
          .style
          ?.fontWeight,
      isNot(FontWeight.w600),
    );
  });

  testWidgets('keeps the slot with a status text when the track is empty',
      (tester) async {
    await mount(tester, cues: SubtitleTrack.empty, position: Duration.zero);
    // 官方 LOADING/ERROR 走 setStatusText，槽位仍在。
    expect(find.byKey(const Key('audio_inline_subtitle')), findsOneWidget);
    expect(find.byKey(const Key('audio-inline-subtitle-status')), findsOneWidget);
    expect(find.text('本章暂无同步字幕'), findsOneWidget);
  });

  testWidgets('collapses only when subtitles are not supported', (tester) async {
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
