import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/audio_page_theme.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/audio_time_format.dart';
import 'package:fqapp/widgets/audio/audio_control_rows.dart';
import 'package:fqapp/widgets/audio/audio_cover_card.dart';
import 'package:fqapp/widgets/audio/audio_real_sections.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

/// 真人讲书页头对齐官方 7.0.9.32 的行为（本轮按反编译重新核对）：
///
///  * `d2.smali` + `TTSPlayHeaderFragment.smali`：智能朗读的封面卡
///    `0.72 × 屏宽`，可见封面是**正方形**（`ahg` 高 = `ah7` − 15dp − 5dp）；
///  * `bjo.xml` + 样稿：真人讲书页头改成 72dp 书籍行（48×64 封面、章节名
///    16sp w600、书名 14sp muted、右侧 ⇋ 开简介卡），不再显示大封面；
///  * `bio.xml` 页脚只有两行：集标题 `b1h` + 副行 `bj2`；书名 `b1g` 官方是
///    `visibility="gone"`，所以不存在旧的「三段页脚 / 真人讲书・第 N 集」；
///  * 副行点一下翻到简介面（`bhi.xml`）再翻回；真人模式改由 ⇋ 弹层展示；
///  * 页头内嵌逐行字幕（`fs6`），无字幕时保留状态槽位；
///  * `hy.xml` 的智能朗读 │ 真人讲书 分段放在页头中央；
///  * `bif.xml` 图标行首项显示当前倍速（截图里的 `1.2x`）；
///  * `bjg.xml` 进度行两端是 `-15 s` / `+15 s` 文字，播放头挂时间药丸；
///  * `bin.xml` 控制行右侧是悬浮圆钮。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
  });

  testWidgets('a recording replaces the large cover with the book row', (
    tester,
  ) async {
    await _mount(tester, _RealSession());
    final row = find.byType(AudioRealBookRow);
    expect(row, findsOneWidget);
    // 真人模式不再渲染 0.72 屏宽的大封面。
    expect(find.byType(AudioFlipCover), findsNothing);
    expect(tester.getSize(row).height, 72);

    final cover = find.byKey(const Key('audio_real_book_cover'));
    expect(tester.getSize(cover), const Size(48, 64));
    expect(tester.getRect(cover).left, 20);

    // 右侧 ⇋：28dp 按钮、r6、16dp 图标，距右 20dp。
    final swap = find.byKey(const Key('audio_real_swap'));
    expect(tester.getSize(swap), const Size(28, 28));
    expect(tester.getRect(swap).right, 430 - 20);
    final swapIcon = tester.widget<Icon>(
      find.descendant(of: swap, matching: find.byType(Icon)),
    );
    expect(swapIcon.size, 16);

    final theme = AudioPageThemeScope.of(tester.element(row));
    final chapter = tester.widget<Text>(
      find.byKey(const Key('audio_chapter_title')),
    );
    expect(chapter.data, '第1章');
    expect(chapter.style?.fontSize, 16);
    expect(chapter.style?.fontWeight, FontWeight.w600);
    // 书名取 detail.title，14sp muted。
    final book = tester.widget<Text>(
      find.byKey(const Key('audio_real_book_title')),
    );
    expect(book.data, '测试听书');
    expect(book.style?.fontSize, 14);
    expect(book.style?.color, theme.muted);
  });

  testWidgets('intelligent reading keeps the large cover, not the book row', (
    tester,
  ) async {
    await _mount(tester, _RealSession(genreType: 0));
    expect(find.byType(AudioFlipCover), findsOneWidget);
    expect(find.byType(AudioRealBookRow), findsNothing);
  });

  testWidgets('the swap button opens the intro card sheet', (tester) async {
    await _mount(tester, _RealSession());
    expect(find.byKey(const Key('audio_intro_title')), findsNothing);

    await tester.tap(find.byKey(const Key('audio_real_swap')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_intro_title')), findsOneWidget);
    expect(find.text('老恒'), findsOneWidget);
    expect(find.textContaining('都市脑洞'), findsOneWidget);
    expect(find.textContaining('这是一段用于对齐的简介'), findsOneWidget);

    // 点弹层外的遮罩收起。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_intro_title')), findsNothing);
    expect(find.byType(AudioRealBookRow), findsOneWidget);
  });

  testWidgets(
    'the header subtitle follows playback and clears without a track',
    (tester) async {
      final session = _RealSession(
        subtitles: (itemId, _) async =>
            itemId == '1' ? _track : SubtitleTrack.empty,
      );
      await _mount(tester, session);
      expect(find.text('第一句同步字幕'), findsOneWidget);
      expect(find.text('第二句同步字幕'), findsOneWidget);
      expect(find.byKey(const Key('audio_real_subtitle')), findsOneWidget);

      session.players.single.emitPosition(const Duration(seconds: 5));
      await _flush(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('audio_real_subtitle_current')))
            .data,
        '第二句同步字幕',
      );

      await tester.tap(find.byTooltip('下一章'));
      await _flush(tester);
      expect(
        find.byKey(const Key('audio_real_subtitle_current')),
        findsNothing,
      );
      // 官方槽位常驻：换到无字幕轨的章节后，`setStatusText` 接替字幕内容，
      // 只有 NOT_SUPPORT 才整块 gone。
      expect(find.byKey(const Key('audio_real_subtitle')), findsOneWidget);
      expect(
        find.byKey(const Key('audio_real_subtitle_status')),
        findsOneWidget,
      );
    },
  );

  testWidgets('inline final lines follow live player duration updates', (
    tester,
  ) async {
    final session = _RealSession(
      subtitles: (_, _) async => SubtitleTrack([
        SubtitleCue(startMs: 0, text: '${'甲' * 23}${'乙' * 23}'),
      ]),
    );
    await _mount(tester, session);
    final current = find.byKey(const Key('audio_real_subtitle_current'));
    final player = session.players.single;
    // The player's initial duration is two minutes, not the cue fallback 6s.
    player.emitPosition(const Duration(seconds: 40));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 650));
    expect(tester.widget<Text>(current).data, '甲' * 23);
    player.emitPosition(const Duration(seconds: 80));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 650));
    expect(tester.widget<Text>(current).data, '乙' * 23);
    player.emitDuration(const Duration(minutes: 4));
    await _flush(tester);
    expect(tester.widget<Text>(current).data, '甲' * 23);
  });

  testWidgets('a recording uses the 238dp strip with 40dp rows', (
    tester,
  ) async {
    const four = SubtitleTrack([
      SubtitleCue(startMs: 0, text: '第一句'),
      SubtitleCue(startMs: 4000, text: '第二句'),
      SubtitleCue(startMs: 8000, text: '第三句'),
      SubtitleCue(startMs: 12000, text: '第四句'),
    ]);
    await _mount(tester, _RealSession(subtitles: (_, _) async => four));

    final slot = find.byKey(const Key('audio_real_subtitle'));
    expect(tester.getSize(slot), const Size(430, 238));
    final theme = AudioPageThemeScope.of(tester.element(slot));
    final current = find.byKey(const Key('audio_real_subtitle_current'));
    expect(tester.widget<Text>(current).data, '第一句');

    // 当前句 20sp w700、主题主色。
    final currentStyle = tester.widget<Text>(current).style!;
    expect(currentStyle.fontSize, AudioRealSubtitle.currentFontSize);
    expect(currentStyle.fontWeight, FontWeight.w700);
    expect(currentStyle.color, theme.ink);

    // 当前句停在第三行（官方 startLine = 3），行高 40dp。
    final slotTop = tester.getTopLeft(slot).dy;
    expect(tester.getCenter(current).dy - slotTop, closeTo(100, 0.6));

    // 普通句 16sp、40% 主色；相邻行正好相距 40dp。
    final second = tester.widget<Text>(find.text('第二句'));
    expect(second.style?.fontSize, 16);
    expect(second.style?.color, theme.ink.withValues(alpha: 0.4));
    expect(
      tester.getCenter(find.text('第三句')).dy -
          tester.getCenter(find.text('第二句')).dy,
      closeTo(40, 0.6),
    );
  });

  testWidgets('the expand tag waits for subtitles and a text timeline', (
    tester,
  ) async {
    final session = _RealSession(subtitles: (_, _) async => _track);
    await _mount(tester, session);
    // 没有时间点时字幕照常显示，只是没有「展开」。
    expect(find.text('第一句同步字幕'), findsOneWidget);
    expect(find.byKey(const Key('audio_real_subtitle_expand')), findsNothing);
    await _unmount(tester);

    final withTimeline = _RealSession(
      subtitles: (_, _) async => _track,
      timePoints: (_, _) async => AudioTimeTrack(const [
        AudioSyncPoint(
          startTime: 0,
          startPara: 0,
          startParaOff: 0,
          endPara: 0,
          endParaOff: 6,
        ),
      ], textItemId: 'novel-chapter'),
    );
    await _mount(tester, withTimeline);
    // 时间点在章节打开后异步到达，下一次播放位置刷新把入口带出来。
    withTimeline.players.single.emitPosition(const Duration(seconds: 2));
    await _flush(tester);

    final expand = find.byKey(const Key('audio_real_subtitle_expand'));
    expect(expand, findsOneWidget);
    final rect = tester.getRect(expand);
    final slot = tester.getRect(find.byKey(const Key('audio_real_subtitle')));
    expect(rect.right, closeTo(slot.right - 20, 0.6));
    expect(rect.bottom, closeTo(slot.bottom - 6, 0.6));
    final label = tester.widget<Text>(find.text('展开'));
    expect(label.style?.fontSize, 12);

    // S3 只留入口，点击暂不切换（S6 接展开态）。
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_real_subtitle')), findsOneWidget);
  });

  testWidgets('the phone header uses the 44dp mockup metrics', (tester) async {
    // 顶栏高度按 MediaQuery 宽度判断，而 `setSurfaceSize` 只改渲染表面，
    // 不改 view 的 physicalSize；这里把两者都设成手机尺寸。
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _mount(tester, _RealSession());
    final bar = find.byType(AudioTopBar);
    expect(tester.getSize(bar).height, AudioTopBar.phoneHeight);
    final back = find.descendant(
      of: bar,
      matching: find.byIcon(LucideIcons.chevron_down),
    );
    final more = find.descendant(
      of: bar,
      matching: find.byIcon(LucideIcons.ellipsis_vertical),
    );
    expect(tester.getSize(back), const Size(24, 24));
    expect(tester.getSize(more), const Size(22, 22));
    // 图标外缘距屏幕边：返回 20dp、更多 16dp。
    expect(tester.getRect(back).left, 20);
    expect(tester.getRect(more).right, 430 - 16);
  });

  testWidgets('the header switch reads 智能朗读 | 真人讲书', (tester) async {
    await _mount(tester, _RealSession());
    final theme = AudioPageThemeScope.of(
      tester.element(find.byType(AudioModeSwitch)),
    );
    Text tabText(String key) => tester.widget<Text>(
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)),
    );
    final tts = tabText('audio_mode_tts');
    final narrator = tabText('audio_mode_narrator');
    expect(tts.data, '智能朗读');
    expect(narrator.data, '真人讲书');
    expect(tts.style?.fontSize, 16);
    expect(narrator.style?.fontSize, 16);
    // 真人讲书选中：w700 + ink；智能朗读未选中：w500 + muted。
    expect(narrator.style?.fontWeight, FontWeight.w700);
    expect(narrator.style?.color, theme.ink);
    expect(tts.style?.fontWeight, FontWeight.w500);
    expect(tts.style?.color, theme.muted);
  });

  testWidgets('the 智能朗读/真人讲书 switch needs both voice families', (tester) async {
    await _mount(tester, _RealSession());
    expect(find.byKey(const Key('audio_mode_tts')), findsOneWidget);
    expect(find.byKey(const Key('audio_mode_narrator')), findsOneWidget);
    await _unmount(tester);

    await _mount(tester, _RealSession(ttsTones: const []));
    expect(find.byKey(const Key('audio_mode_tts')), findsNothing);
    expect(find.byKey(const Key('audio_mode_narrator')), findsNothing);
    // 只有一类声音时退回单标题。
    expect(find.text('听书'), findsOneWidget);
  });

  testWidgets('the narrator row replaces the voice card', (tester) async {
    await _mount(tester, _RealSession());
    // 音色卡的双卡结构不再出现，只剩一行版本入口。
    expect(find.text('边听边读'), findsNothing);
    expect(find.text('主播：老恒'), findsOneWidget);
    expect(find.text('换版本'), findsOneWidget);
    // S2：换版本行外边距收窄到 (12, 10, 12, 0)。
    expect(tester.getRect(find.byKey(const ValueKey('audio-voice'))).left, 12);

    await tester.tap(find.byKey(const ValueKey('audio-voice')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice_settings_close')), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice_settings_close')));
    await tester.pumpAndSettle();
    await _unmount(tester);

    await _mount(tester, _RealSession(narratorTones: const []));
    expect(find.text('暂无可选音色'), findsOneWidget);
  });

  testWidgets('a recording counts episodes in the catalog and the more panel', (
    tester,
  ) async {
    await _mount(tester, _RealSession());
    await tester.tap(find.byKey(const ValueKey('audio_more')));
    await tester.pumpAndSettle();
    expect(find.text('共 3 集'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    // 真人模式的书籍行没有目录入口，目录改由控制行的「目录」按钮打开。
    await tester.ensureVisible(find.text('目录'));
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(find.text('目录 · 3 集'), findsOneWidget);
    expect(find.text('搜索集名或序号'), findsOneWidget);
  });

  testWidgets('transport and progress rows follow bin/bjg', (tester) async {
    await _mount(tester, _RealSession());
    // bin.xml: 目录(axr) 与 定时(i58) 是同构的「图标 + 12sp 文字」，
    // 截图里那颗橙色圆钮是广告浮层，不是定时入口。
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('定时'), findsOneWidget);
    expect(find.byKey(const Key('audio_sleep')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('audio_play'))),
      const Size(60, 60),
    );
    expect(find.byTooltip('上一章'), findsOneWidget);
    expect(find.byTooltip('下一章'), findsOneWidget);
    // bjg + AudioLabelSeekBar: 两端是 -15 s / +15 s 文字，播放头挂时间药丸。
    expect(find.byKey(const ValueKey('audio-seek')), findsOneWidget);
    expect(find.text('-15 s'), findsOneWidget);
    expect(find.text('+15 s'), findsOneWidget);
    expect(find.byKey(const Key('audio-time-pill')), findsOneWidget);
    expect(find.byTooltip('后退15秒'), findsNothing);
    expect(find.byTooltip('前进15秒'), findsNothing);
  });

  testWidgets('the transport row fits a narrow screen', (tester) async {
    await _mount(tester, _RealSession(), size: const Size(320, 640));
    expect(tester.takeException(), isNull);
    expect(find.text('目录'), findsOneWidget);
    expect(find.byKey(const Key('audio_sleep')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('audio_play'))),
      const Size(60, 60),
    );
  });

  testWidgets('the action row follows the 8/6/24 mockup metrics', (
    tester,
  ) async {
    await _mount(tester, _RealSession());
    final row = find.byType(AudioIconRow);
    expect(row, findsOneWidget);

    // 样稿 `.acts`：左右 8、上 8、下 0。
    final subtitle = find.byKey(const Key('audio_real_subtitle'));
    expect(tester.getRect(row).left, 8);
    expect(
      tester.getRect(row).top,
      closeTo(tester.getRect(subtitle).bottom + 8, 0.6),
    );

    final speed = find.byKey(const ValueKey('audio-speed'));
    final icon = find.descendant(of: speed, matching: find.byType(Icon));
    final label = find.descendant(of: speed, matching: find.byType(Text));
    expect(tester.widget<Icon>(icon).size, 24);
    expect(tester.widget<Text>(label).style?.fontSize, 12);
    expect(
      tester.getRect(label).top - tester.getRect(icon).bottom,
      closeTo(6, 0.1),
    );

    // 真人模式的图标：仪表、加号书、下载、评论、更多。
    expect(find.byIcon(LucideIcons.gauge), findsOneWidget);
    expect(find.byIcon(LucideIcons.book_plus), findsOneWidget);
    expect(find.byIcon(LucideIcons.download), findsOneWidget);
    expect(find.byIcon(LucideIcons.message_circle), findsOneWidget);
    expect(find.byIcon(LucideIcons.circle_ellipsis), findsOneWidget);
  });

  testWidgets('the progress row follows the 44dp mockup', (tester) async {
    final session = _RealSession();
    await _mount(tester, session);
    final theme = AudioPageThemeScope.of(
      tester.element(find.byType(AudioTimeSeekRow)),
    );
    expect(
      tester.getSize(find.byType(AudioTimeSeekRow)).height,
      AudioTimeSeekRow.realHeight,
    );

    // −15s / +15s：12sp ink。
    for (final text in ['-15 s', '+15 s']) {
      final label = tester.widget<Text>(find.text(text));
      expect(label.style?.fontSize, 12);
      expect(label.style?.color, theme.ink);
    }
    // 轨道 2dp。
    final slider = find.byKey(const ValueKey('audio-seek'));
    expect(SliderTheme.of(tester.element(slider)).trackHeight, 2);

    // 时间药丸：18dp 高、r4、10.5sp、accent 底、canvas 字色。
    final pill = find.byKey(const Key('audio-time-pill'));
    expect(tester.getSize(pill).height, AudioTimeSeekRow.realPillHeight);
    final decoration =
        tester.widget<Container>(pill).decoration! as BoxDecoration;
    expect(decoration.color, theme.accent);
    expect(decoration.borderRadius, BorderRadius.circular(4));
    final pillText = tester.widget<Text>(
      find.descendant(of: pill, matching: find.byType(Text)),
    );
    expect(pillText.style?.fontSize, AudioTimeSeekRow.realPillFontSize);
    expect(pillText.style?.color, theme.canvas);
    expect(pillText.data, '00:00/02:00');

    // 药丸中心跟着播放头走，两端夹回轨道内。
    session.players.single.emitPosition(const Duration(seconds: 60));
    await _flush(tester);
    final sliderRect = tester.getRect(slider);
    final pillRect = tester.getRect(pill);
    expect(
      pillRect.left - sliderRect.left,
      closeTo(sliderRect.width / 2 - pillRect.width / 2, 0.6),
    );
    session.players.single.emitPosition(const Duration(seconds: 120));
    await _flush(tester);
    expect(tester.getRect(pill).right, closeTo(sliderRect.right, 0.6));
  });

  testWidgets('the transport row follows the 48/34/26/40 mockup', (
    tester,
  ) async {
    await _mount(tester, _RealSession());
    final theme = AudioPageThemeScope.of(
      tester.element(find.byType(AudioTransportRow)),
    );

    final play = find.byKey(const Key('audio_play'));
    expect(tester.getSize(play), const Size(60, 60));
    expect(
      tester.getSize(find.descendant(of: play, matching: find.byType(Icon))),
      const Size.square(AudioTransportRow.realPlayIconSize),
    );

    // 两侧槽位 48dp，图标-文字间距 4dp，文字 ink。
    final catalog = find.byTooltip('目录');
    final catalogIcon = find.descendant(
      of: catalog,
      matching: find.byType(Icon),
    );
    final catalogLabel = find.descendant(
      of: catalog,
      matching: find.byType(Text),
    );
    expect(tester.getSize(catalog).width, AudioTransportRow.realSideWidth);
    expect(
      tester.getSize(find.byKey(const Key('audio_sleep'))).width,
      AudioTransportRow.realSideWidth,
    );
    expect(
      tester.getRect(catalogLabel).top - tester.getRect(catalogIcon).bottom,
      closeTo(4, 0.1),
    );
    expect(tester.widget<Text>(catalogLabel).style?.color, theme.ink);

    // 换章图标 26dp，播放键与换章的间距 40dp。
    final previous = find.byTooltip('上一章');
    final next = find.byTooltip('下一章');
    expect(tester.getSize(previous), const Size(26, 26));
    expect(tester.getSize(next), const Size(26, 26));
    expect(
      tester.getSize(find.descendant(of: next, matching: find.byType(Icon))),
      const Size.square(AudioTransportRow.realChapterIconSize),
    );
    final playRect = tester.getRect(play);
    expect(tester.getRect(next).left - playRect.right, closeTo(40, 0.6));
    expect(playRect.left - tester.getRect(previous).right, closeTo(40, 0.6));
  });

  testWidgets('the pill switches to H:MM:SS past an hour', (tester) async {
    final session = _RealSession();
    await _mount(tester, session);
    session.players.single.emitDuration(
      const Duration(hours: 1, minutes: 5, seconds: 3),
    );
    await _flush(tester);
    expect(find.text('0:00:00/1:05:03'), findsOneWidget);
  });

  test('the audio time formatter keeps hours in their own column', () {
    expect(formatAudioTime(const Duration(minutes: 10, seconds: 36)), '10:36');
    expect(
      formatAudioTime(const Duration(hours: 1, minutes: 2, seconds: 5)),
      '1:02:05',
    );
    expect(
      formatAudioProgress(
        const Duration(seconds: 13),
        const Duration(minutes: 10, seconds: 36),
      ),
      '00:13/10:36',
    );
    // 总时长满一小时后，当前时间也补出小时位。
    expect(
      formatAudioProgress(
        const Duration(minutes: 2, seconds: 5),
        const Duration(hours: 1, minutes: 5, seconds: 3),
      ),
      '0:02:05/1:05:03',
    );
  });

  testWidgets('the bare transport row keeps icons without labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 430,
            child: AudioTransportRow(
              real: true,
              bare: true,
              onCatalog: _noop,
              onSleepTimer: _noop,
            ),
          ),
        ),
      ),
    );
    expect(find.text('目录'), findsNothing);
    expect(find.text('定时'), findsNothing);
    expect(find.byTooltip('目录'), findsOneWidget);
    expect(find.byTooltip('定时'), findsOneWidget);
    expect(find.byIcon(LucideIcons.list), findsOneWidget);
    expect(find.byIcon(LucideIcons.timer), findsOneWidget);
  });
}

void _noop() {}

const _track = SubtitleTrack([
  SubtitleCue(startMs: 0, text: '第一句同步字幕'),
  SubtitleCue(startMs: 4000, text: '第二句同步字幕'),
]);

AudioSource _source(String id, String? toneId) => AudioSource(
  itemId: id,
  url: 'https://example.invalid/$id-${toneId ?? '0'}.mp3',
  toneId: toneId ?? '0',
);

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _flush(tester);
}

Future<void> _mount(
  WidgetTester tester,
  _RealSession session, {
  Size size = const Size(430, 932),
}) async {
  await tester.binding.setSurfaceSize(size);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await _unmount(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

/// A 真人讲书 book: `genre_type == 1`, one narrator version, one linked TTS
/// novel, and a populated detail for the intro side.
class _RealSession {
  final Future<SubtitleTrack> Function(String itemId, String toneId) subtitles;
  final Future<AudioTimeTrack> Function(String itemId, String toneId)
  timePoints;
  final List<AudioTone> narratorTones;
  final List<AudioTone> ttsTones;
  final int genreType;
  final List<RelatedWork> related = const [
    RelatedWork(
      kind: 'book',
      id: '7180279419959774247',
      title: '原著小说同名作品',
      label: '原著小说',
    ),
  ];
  final List<_AudioPlayer> players = [];

  _RealSession({
    this.subtitles = _noSubtitles,
    this.timePoints = _noTimePoints,
    this.narratorTones = const [
      AudioTone(id: '7239243941252598845', title: '主播：老恒'),
    ],
    this.ttsTones = const [AudioTone(id: '96', title: '多角色对话升级版')],
    this.genreType = 1,
  });

  static Future<AudioTimeTrack> _noTimePoints(String _, String _) async =>
      AudioTimeTrack.empty;

  static Future<SubtitleTrack> _noSubtitles(String _, String _) async =>
      SubtitleTrack.empty;

  Widget app() => MaterialApp(
    home: AudioPage(
      bookId: 'book',
      title: '测试听书',
      chapters: [
        for (var index = 1; index <= 3; index++)
          Chapter(itemId: '$index', title: '第$index章', volumeName: '第一卷'),
      ],
      historyStore: ControlledReaderStore(),
      sourceLoader: (id, {toneId}) async => _source(id, toneId),
      voicesLoader: () async => const [],
      subtitleLoader: (itemId, toneId) => subtitles(itemId, toneId),
      timePointLoader: (itemId, toneId) => timePoints(itemId, toneId),
      excerptLoader: (_) async => null,
      extrasLoader: (_) async => AudioExtras(
        tones: AudioToneSet(
          genreType: genreType,
          narratorTones: narratorTones,
          ttsTones: ttsTones,
        ),
        related: related,
        detail: const BookDetail(
          bookId: 'book',
          title: '测试听书',
          author: BookAuthor(name: '老恒'),
          abstract:
              '这是一段用于对齐的简介，长度足够触发展开按钮的显示阈值，'
              '因此简介面会渲染「展开」入口而不是空白。',
          category: '都市脑洞',
          creationStatus: 1,
          wordNumber: 1328318,
        ),
      ),
      playerFactory: () {
        final player = _AudioPlayer();
        players.add(player);
        return player;
      },
    ),
  );
}

class _AudioPlayer extends ControlledNativePlayer {
  _AudioPlayer();
}
