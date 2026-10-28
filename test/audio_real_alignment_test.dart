import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/audio_preferences.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

/// 真人讲书页头对齐官方 7.0.9.32 的行为（本轮按反编译重新核对）：
///
///  * `d2.smali` + `TTSPlayHeaderFragment.smali`：封面卡 `0.72 × 屏宽`、
///    高度 = 宽 + 20dp，可见封面是**正方形**（`ahg` 高 = `ah7` − 15dp − 5dp）；
///  * `bio.xml` 页脚只有两行：集标题 `b1h` + 副行 `bj2`；书名 `b1g` 官方是
///    `visibility="gone"`，所以不存在旧的「三段页脚 / 真人讲书・第 N 集」；
///  * 副行点一下翻到简介面（`bhi.xml`）再翻回；
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

  testWidgets('a recording keeps the official two-line cover footer', (
    tester,
  ) async {
    await _mount(tester, _RealSession());
    expect(
      tester.widget<Text>(find.byKey(const Key('audio_chapter_title'))).data,
      '第1章',
    );
    // 官方 bio.xml 的 b1g（书名行）是 visibility="gone"，封面页脚只有两行，
    // 所以书书名和旧的「真人讲书・第 N 集」都不该出现。
    expect(find.text('测试听书'), findsNothing);
    expect(find.textContaining('真人讲书・第'), findsNothing);
  });

  testWidgets('the cover flips to the intro card and back', (tester) async {
    await _mount(tester, _RealSession());
    expect(find.byKey(const Key('audio_intro_title')), findsNothing);

    await tester.tap(find.byKey(const Key('audio_mode_row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_intro_title')), findsOneWidget);
    expect(find.text('老恒'), findsOneWidget);
    expect(find.textContaining('都市脑洞'), findsOneWidget);
    expect(find.textContaining('这是一段用于对齐的简介'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio_cover_back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_intro_title')), findsNothing);
    expect(find.byKey(const Key('audio_chapter_title')), findsOneWidget);
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
      expect(find.byKey(const Key('audio_inline_subtitle')), findsOneWidget);

      session.players.single.emitPosition(const Duration(seconds: 5));
      await _flush(tester);
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('audio-inline-subtitle-current')),
            )
            .data,
        '第二句同步字幕',
      );

      await tester.tap(find.byTooltip('下一章'));
      await _flush(tester);
      expect(
        find.byKey(const Key('audio-inline-subtitle-current')),
        findsNothing,
      );
      // 官方槽位常驻：换到无字幕轨的章节后，`setStatusText` 接替字幕内容，
      // 只有 NOT_SUPPORT 才整块 gone。
      expect(find.byKey(const Key('audio_inline_subtitle')), findsOneWidget);
      expect(
        find.byKey(const Key('audio-inline-subtitle-status')),
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
    final current = find.byKey(const Key('audio-inline-subtitle-current'));
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

  testWidgets('the AI朗读/真人讲书 switch needs both voice families', (tester) async {
    await _mount(tester, _RealSession());
    expect(find.byKey(const Key('audio_mode_tts')), findsOneWidget);
    expect(find.byKey(const Key('audio_mode_narrator')), findsOneWidget);
    await _unmount(tester);

    await _mount(tester, _RealSession(ttsTones: const []));
    expect(find.byKey(const Key('audio_mode_tts')), findsNothing);
    expect(find.byKey(const Key('audio_mode_narrator')), findsNothing);
  });

  testWidgets('the narrator row replaces the voice card', (tester) async {
    await _mount(tester, _RealSession());
    // 音色卡的双卡结构不再出现，只剩一行版本入口。
    expect(find.text('边听边读'), findsNothing);
    expect(find.text('主播：老恒'), findsOneWidget);
    expect(find.text('换版本'), findsOneWidget);

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

    // 官方书名行 `b1g` 默认 gone，但仓库一直用 `audio_book_bar` 开目录，
    // 所以实现里它渲染为空字符串占位：看不见，但仍是目录入口。
    await tester.ensureVisible(find.byKey(const Key('audio_book_bar')));
    await tester.tap(find.byKey(const Key('audio_book_bar')));
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
}

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
  final List<AudioTone> narratorTones;
  final List<AudioTone> ttsTones;
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
    this.narratorTones = const [
      AudioTone(id: '7239243941252598845', title: '主播：老恒'),
    ],
    this.ttsTones = const [AudioTone(id: '96', title: '多角色对话升级版')],
  });

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
      excerptLoader: (_) async => null,
      extrasLoader: (_) async => AudioExtras(
        tones: AudioToneSet(
          genreType: 1,
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
