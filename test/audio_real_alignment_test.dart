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

/// 真人讲书页头对齐官方 7.0.9.32 的行为：
///
///  * `bio.xml` 三段页脚（集标题 / 书名 / `真人讲书・第 N 集`）与 72% 封面；
///  * 封面翻转到简介面（`bhi.xml`）再翻回；
///  * 页头内嵌双行字幕（`fs6`），无字幕时不占位；
///  * `hy.xml` 的 AI朗读 │ 真人讲书 分段只在两族音源都存在时出现；
///  * 真人模式用一行版本入口替代音色卡（`bj1.xml` a5h 默认 gone）；
///  * 目录与更多面板按「集」计数。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
  });

  testWidgets('a recording keeps the official three-line cover header', (
    tester,
  ) async {
    await _mount(tester, _RealSession());
    expect(
      tester.widget<Text>(find.byKey(const Key('audio_chapter_title'))).data,
      '第1章',
    );
    expect(find.text('测试听书'), findsOneWidget);
    expect(find.text('真人讲书・第 1 集'), findsOneWidget);
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
      expect(find.byKey(const Key('audio_read_along')), findsOneWidget);

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
      expect(find.byKey(const Key('audio_read_along')), findsNothing);
    },
  );

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

    await tester.ensureVisible(find.byKey(const Key('audio_book_bar')));
    await tester.tap(find.byKey(const Key('audio_book_bar')));
    await tester.pumpAndSettle();
    expect(find.text('目录 · 3 集'), findsOneWidget);
    expect(find.text('搜索集名或序号'), findsOneWidget);
  });

  testWidgets('transport and progress rows follow bin/bjg', (tester) async {
    await _mount(tester, _RealSession());
    // bin.xml: 只有目录/定时带 12sp 文字，播放键 60dp。
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('定时'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('audio_play'))),
      const Size(60, 60),
    );
    expect(find.byTooltip('上一章'), findsOneWidget);
    expect(find.byTooltip('下一章'), findsOneWidget);
    // bjg.xml: 24dp 图标夹细轨，官方默认不显示时间文字。
    expect(find.byKey(const ValueKey('audio-seek')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-position-label')), findsNothing);
    expect(find.byTooltip('后退15秒'), findsOneWidget);
    expect(find.byTooltip('前进15秒'), findsOneWidget);
  });

  testWidgets('the transport row fits a narrow screen', (tester) async {
    await _mount(tester, _RealSession(), size: const Size(320, 640));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('目录'), findsOneWidget);
    expect(find.byTooltip('定时'), findsOneWidget);
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
