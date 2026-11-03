import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/services/audio_page_theme.dart';
import 'package:fqapp/widgets/audio/audio_real_sections.dart';
import 'package:fqapp/widgets/audio/audio_subtitle_scroller.dart';

/// Both listening modes now use the same compact, three-line-anchored strip.
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
    Duration duration = const Duration(seconds: 26),
    double width = 393,
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
                  child: AudioRealSubtitle(
                    track: cues,
                    position: position,
                    duration: duration,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('centers the current line in the third 40dp row', (tester) async {
    await mount(tester, cues: track, position: const Duration(seconds: 4));
    final current = find.byKey(const Key('audio_real_subtitle_current'));
    expect(tester.widget<Text>(current).data, '第二句');
    final slotTop = tester.getTopLeft(
      find.byKey(const Key('audio_real_subtitle')),
    );
    expect(tester.getCenter(current).dy - slotTop.dy, closeTo(100, 0.6));
  });

  testWidgets('keeps the previous line above the current row', (tester) async {
    await mount(tester, cues: track, position: const Duration(seconds: 4));
    final slotTop = tester.getTopLeft(
      find.byKey(const Key('audio_real_subtitle')),
    );
    final previous = tester.getCenter(find.text('第一句'));
    expect(previous.dy - slotTop.dy, closeTo(60, 0.6));
  });

  testWidgets('splits a long cue into independently timed display lines', (
    tester,
  ) async {
    const long = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '一一一一一一一一一一一一一一一一一一一一一二二二二二'),
    ]);
    await mount(tester, cues: long, position: const Duration(seconds: 1));
    final current = find.byKey(const Key('audio_real_subtitle_current'));
    final size = tester.getSize(current);
    expect(tester.widget<Text>(current).data, '一' * 21);
    expect(size.height, lessThan(30));
    final remainder = '二' * 5;
    final next = find.text(remainder);
    expect(next, findsOneWidget);
    expect(
      tester.widget<Text>(next).style?.color,
      AudioPageTheme.fallback.ink.withValues(alpha: 0.4),
    );
    expect(
      tester.getCenter(next).dy - tester.getCenter(current).dy,
      closeTo(40, 0.6),
    );
    final slotTop = tester.getTopLeft(
      find.byKey(const Key('audio_real_subtitle')),
    );
    expect(tester.getCenter(current).dy - slotTop.dy, closeTo(100, 0.6));
    await mount(tester, cues: long, position: const Duration(seconds: 22));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(current).data, remainder);
    expect(tester.getCenter(current).dy - slotTop.dy, closeTo(100, 0.6));
  });

  testWidgets('uses muted context and a bold current line within edge fading', (
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
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio_real_subtitle_current')))
          .style
          ?.fontWeight,
      FontWeight.w700,
    );
    expect(
      find.ancestor(
        of: find.byKey(const Key('audio_real_subtitle_current')),
        matching: find.byType(ShaderMask),
      ),
      findsOneWidget,
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
    expect(find.byKey(const Key('audio_real_subtitle')), findsOneWidget);
    expect(find.byKey(const Key('audio_real_subtitle_status')), findsOneWidget);
    expect(find.text('本章暂无同步字幕'), findsOneWidget);
  });

  testWidgets('keeps the same slot when a populated track becomes empty', (
    tester,
  ) async {
    await mount(tester, cues: track, position: Duration.zero);
    final before = tester.getSize(find.byKey(const Key('audio_real_subtitle')));
    await mount(tester, cues: SubtitleTrack.empty, position: Duration.zero);
    expect(
      tester.getSize(find.byKey(const Key('audio_real_subtitle'))),
      before,
    );
    expect(find.byType(AudioSubtitleScroller), findsNothing);
    expect(find.text('本章暂无同步字幕'), findsOneWidget);
  });

  testWidgets('uses a 238dp slot with 20dp horizontal padding', (tester) async {
    await mount(tester, cues: track, position: Duration.zero);
    expect(
      tester.getSize(find.byKey(const Key('audio_real_subtitle'))).height,
      238,
    );
    final padding = tester.widget<Padding>(
      find
          .ancestor(
            of: find.byType(AudioSubtitleScroller),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(padding.padding, const EdgeInsets.symmetric(horizontal: 20));
  });

  testWidgets('seeking before the first cue resets the offset', (tester) async {
    const delayed = SubtitleTrack([
      SubtitleCue(startMs: 1000, text: 'first'),
      SubtitleCue(startMs: 3000, text: 'second'),
    ]);
    await mount(tester, cues: delayed, position: const Duration(seconds: 4));
    await mount(tester, cues: delayed, position: Duration.zero);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_real_subtitle_current')), findsNothing);
    expect(
      tester.getCenter(find.text('first')).dy -
          tester.getTopLeft(find.byKey(const Key('audio_real_subtitle'))).dy,
      closeTo(100, 0.6),
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
      tester.getCenter(find.text('第三句')).dy -
          tester.getTopLeft(find.byKey(const Key('audio_real_subtitle'))).dy,
      closeTo(100, 0.6),
    );
    await mount(tester, cues: track, position: Duration.zero);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio_real_subtitle_current')))
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
      tester.getSize(find.byKey(const Key('audio_real_subtitle'))).height,
      476,
    );
    expect(
      tester.getCenter(find.text('第二句')).dy -
          tester.getCenter(find.text('第一句')).dy,
      closeTo(80, 0.6),
    );
  });

  testWidgets(
    'reflows equal-count replacement tracks and text scale or width changes',
    (tester) async {
      final current = find.byKey(const Key('audio_real_subtitle_current'));
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
        scale: 1.5,
      );
      expect(tester.widget<Text>(current).data!.length, lessThan(before));
      expect(
        tester.getSize(find.byKey(const Key('audio_real_subtitle'))).height,
        357,
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
        of: find.byKey(const Key('audio_real_subtitle_status')),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );
    await mount(tester, cues: track, position: const Duration(seconds: 6));
    expect(
      tester
          .widget<Text>(find.byKey(const Key('audio_real_subtitle_current')))
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
          .widget<Text>(find.byKey(const Key('audio_real_subtitle_current')))
          .data,
      'row 800',
    );
    final rows = find.descendant(
      of: find.byType(AudioSubtitleScroller),
      matching: find.byType(Text),
    );
    expect(rows.evaluate().length, lessThanOrEqualTo(7));
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
