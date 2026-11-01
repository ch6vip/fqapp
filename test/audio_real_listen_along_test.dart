import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/audio_page_theme.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

/// 边听边读与会话别名（规格 S7）：
///
///  * 真人讲书页多一张 40dp 的「边听边读」卡，右边显示时间轴映射到的
///    原著章节；映射不到（无时间轴 / 无关联原著）时整行隐藏；
///  * 点开的是关联原著的阅读页，定位到 `novel_item_id` 对应的章节；
///  * 会话按音频（专辑）id 发布，阅读页按原著 id 打开；两个 id 通过
///    [ListeningSession] 的别名互相匹配，高亮/跟随/迷你栏才不会断。
const _audioBook = '7239243941252598845';
const _novelBook = '7180279419959774247';
const _audioChapter = '7250158428088454201';
const _novelChapter = '7181453438667096588';

const _timeTrack = AudioTimeTrack(
  [
    AudioSyncPoint(
      startTime: 0,
      startPara: 1,
      startParaOff: 0,
      endPara: 1,
      endParaOff: 6,
    ),
  ],
  textItemId: _novelChapter,
  novelItemId: _novelChapter,
  novelChapterTitle: '第1章 下山那天',
);

/// 时间点齐全但没有原著章节 id：卡片必须隐藏。
const _trackWithoutNovel = AudioTimeTrack([
  AudioSyncPoint(
    startTime: 0,
    startPara: 1,
    startParaOff: 0,
    endPara: 1,
    endParaOff: 6,
  ),
]);

const _subtitleTrack = SubtitleTrack([
  SubtitleCue(startMs: 0, text: '第一句同步字幕'),
]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
  });

  testWidgets('the read-along card shows the mapped novel chapter', (
    tester,
  ) async {
    await _mount(tester, _ListenAlongSession());

    final card = find.byKey(const Key('audio_real_read_along'));
    expect(card, findsOneWidget);
    // 40dp 高、r10，外边距左右各 12。
    expect(tester.getSize(card), const Size(406, 40));
    expect(tester.getRect(card).left, 12);

    final theme = AudioPageThemeScope.of(tester.element(card));
    final box = tester.widget<Container>(
      find.descendant(of: card, matching: find.byType(Container)).first,
    );
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, theme.card);
    expect(decoration.borderRadius, BorderRadius.circular(10));

    final title = tester.widget<Text>(find.text('边听边读'));
    expect(title.style?.fontSize, 14);
    expect(title.style?.fontWeight, FontWeight.w600);
    expect(title.style?.color, theme.ink);

    final chapter = tester.widget<Text>(find.text('第1章 下山那天'));
    expect(chapter.style?.fontSize, 13);
    expect(chapter.style?.color, theme.muted);

    final arrow = find.descendant(
      of: card,
      matching: find.byIcon(LucideIcons.chevron_right),
    );
    expect(arrow, findsOneWidget);
    expect(tester.widget<Icon>(arrow).size, 14);
    expect(tester.widget<Icon>(arrow).color, theme.muted);
  });

  testWidgets('the read-along card hides without a novel mapping', (
    tester,
  ) async {
    await _mount(tester, _ListenAlongSession(timeTrack: AudioTimeTrack.empty));
    expect(find.byKey(const Key('audio_real_read_along')), findsNothing);
    await _unmount(tester);

    await _mount(tester, _ListenAlongSession(timeTrack: _trackWithoutNovel));
    expect(find.byKey(const Key('audio_real_read_along')), findsNothing);
    await _unmount(tester);

    // 有时间轴，但这张录音没有关联原著：没有可打开的阅读页，入口同样隐藏。
    await _mount(tester, _ListenAlongSession(withNovel: false));
    expect(find.byKey(const Key('audio_real_read_along')), findsNothing);
  });

  testWidgets('the card opens the novel reader on the mapped chapter', (
    tester,
  ) async {
    final session = _ListenAlongSession();
    await _mount(tester, session);

    // 控制器的会话别名已经带上原著 id，阅读页才能继续匹配播放状态。
    expect(ListeningSession.instance.matchesBook(_novelBook), isTrue);
    expect(ListeningSession.instance.matchesChapter(_novelChapter), isTrue);

    final card = find.byKey(const Key('audio_real_read_along'));
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(session.directoryRequests, [_novelBook]);
    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(reader.bookId, _novelBook);
    expect(reader.title, '原著小说');
    expect(reader.chapters, hasLength(3));
    expect(reader.startIndex, 1);
    expect(reader.chapters[reader.startIndex].itemId, _novelChapter);
  });

  test('the session matches both the audio and the novel identity', () {
    final session = ListeningSession.instance;
    session.update(
      bookId: _audioBook,
      chapterId: _audioChapter,
      chapterTitle: '001 下山那天',
      position: const Duration(seconds: 3),
      duration: const Duration(minutes: 10),
      playing: true,
      novelBookId: _novelBook,
      novelChapterId: _novelChapter,
    );

    expect(session.matchesBook(_audioBook), isTrue);
    expect(session.matchesBook(_novelBook), isTrue);
    expect(session.matchesBook('another-book'), isFalse);
    expect(session.matchesChapter(_audioChapter), isTrue);
    expect(session.matchesChapter(_novelChapter), isTrue);
    expect(session.matchesChapter('another-chapter'), isFalse);
    expect(session.matches(_novelBook, _novelChapter), isTrue);
    expect(session.matches(_audioBook, _audioChapter), isTrue);
    expect(session.readerChapterId, _novelChapter);

    // 打开原著的阅读页要默认跟随（官方 onPlayStart）。
    session.setFollowArmed(false);
    session.followIfPlaying(_novelBook);
    expect(session.followArmed, isTrue);

    // 时间轴还没给出原著映射时，别把任意章节当成正在读的那一章。
    session.update(
      bookId: _audioBook,
      chapterId: _audioChapter,
      chapterTitle: '001 下山那天',
      position: Duration.zero,
      duration: const Duration(minutes: 10),
      playing: true,
      novelBookId: _novelBook,
    );
    expect(session.matchesChapter(_novelChapter), isFalse);
    expect(session.readerChapterId, _audioChapter);
  });

  test('clear drops the novel alias', () {
    final session = ListeningSession.instance;
    session.update(
      bookId: _audioBook,
      chapterId: _audioChapter,
      chapterTitle: '001 下山那天',
      position: Duration.zero,
      duration: const Duration(minutes: 10),
      playing: true,
      novelBookId: _novelBook,
      novelChapterId: _novelChapter,
    );
    session.clear();

    expect(session.matchesBook(_novelBook), isFalse);
    expect(session.matchesChapter(_novelChapter), isFalse);
    expect(session.readerChapterId, isNull);
  });
}

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
  _ListenAlongSession session, {
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
  // 字幕/时间点是异步到达的；再推一拍让快照带上章节映射。
  session.players.single.emitPosition(const Duration(seconds: 1));
  await _flush(tester);
}

List<Chapter> _novelChapters() => [
  Chapter(itemId: 'novel-0', title: '序章', volumeName: ''),
  Chapter(itemId: _novelChapter, title: '第1章 下山那天', volumeName: ''),
  Chapter(itemId: 'novel-2', title: '第2章 练剑', volumeName: ''),
];

ChapterContent _chapterContent() => ChapterContent(
  blocks: const [
    ChapterParagraph('第1章 下山那天', paraIndex: 0),
    ChapterParagraph('山门外的雾还没散，师姐打了个哈欠。', paraIndex: 1),
  ],
);

class _ListenAlongSession {
  final bool withNovel;
  final AudioTimeTrack timeTrack;
  final List<String> directoryRequests = [];
  final List<_AudioPlayer> players = [];

  _ListenAlongSession({this.withNovel = true, this.timeTrack = _timeTrack});

  Widget app() => MaterialApp(
    home: AudioPage(
      bookId: _audioBook,
      title: '测试听书',
      chapters: [
        Chapter(itemId: _audioChapter, title: '第1章', volumeName: '第一卷'),
      ],
      historyStore: ControlledReaderStore(),
      sourceLoader: (id, {toneId}) async => AudioSource(
        itemId: id,
        url: 'https://example.invalid/$id-${toneId ?? '0'}.mp3',
        toneId: toneId ?? '0',
      ),
      voicesLoader: () async => const [],
      subtitleLoader: (_, _) async => _subtitleTrack,
      timePointLoader: (_, _) async => timeTrack,
      contentLoader: (_) async => _chapterContent(),
      directoryLoader: (bookId) async {
        directoryRequests.add(bookId);
        return _novelChapters();
      },
      excerptLoader: (_) async => null,
      extrasLoader: (_) async => AudioExtras(
        tones: AudioToneSet(
          genreType: 1,
          narratorTones: const [AudioTone(id: _audioBook, title: '主播：老恒')],
          ttsTones: const [AudioTone(id: '96', title: '多角色对话升级版')],
          relatedNovel: withNovel
              ? const RelatedWork(
                  kind: 'book',
                  id: _novelBook,
                  title: '原著小说',
                  label: '原著小说',
                )
              : null,
        ),
        detail: const BookDetail(
          bookId: _audioBook,
          title: '测试听书',
          author: BookAuthor(name: '老恒'),
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
