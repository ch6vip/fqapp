import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';
import 'package:fqapp/widgets/detail/detail_reviews.dart';
import 'package:fqapp/widgets/detail/detail_sections.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_status_bar.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

const _track = SubtitleTrack([
  SubtitleCue(startMs: 0, text: '第一句同步字幕'),
  SubtitleCue(startMs: 8000, text: '第二句同步字幕'),
]);
const _nextTrack = SubtitleTrack([SubtitleCue(startMs: 0, text: '下一章同步字幕')]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('the audio cover voice button wins over the catalog tap target', (
    tester,
  ) async {
    var voices = 0;
    var catalog = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AudioBookCard(
            bookTitle: '听书',
            chapterTitle: '第一章',
            onSwitch: () => voices++,
            onOpenBook: () => catalog++,
          ),
        ),
      ),
    );
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('audio_cover_switch'))),
    );
    await tester.pump();
    expect(voices, 1);
    expect(catalog, 0);
    await tester.tapAt(tester.getCenter(find.byType(AudioBookCard)));
    await tester.pump();
    expect(voices, 1);
    expect(catalog, 1);
    await tester.tap(find.byKey(const Key('audio_book_bar')));
    await tester.pump();
    expect(voices, 1);
    expect(catalog, 2);
  });

  testWidgets('an open read-along sheet receives late subtitles', (
    tester,
  ) async {
    final subtitles = Completer<SubtitleTrack>();
    await _mount(tester, _AudioSession((_, _) => subtitles.future).app());
    await _openReadAlong(tester);
    expect(find.text('本章暂无同步字幕'), findsOneWidget);
    subtitles.complete(_track);
    await _flush(tester);
    expect(_currentSubtitle(tester), '第一句同步字幕');
    expect(find.text('本章暂无同步字幕'), findsNothing);
  });

  testWidgets(
    'read-along follows playback and clears on automatic chapter change',
    (tester) async {
      final nextSubtitles = Completer<SubtitleTrack>();
      final session = _AudioSession(
        (id, _) async => id == 'c1' ? _track : nextSubtitles.future,
      );
      await _mount(tester, session.app());
      await _openReadAlong(tester);
      expect(_currentSubtitle(tester), '第一句同步字幕');
      session.players.first.emitPosition(const Duration(seconds: 9));
      await _flush(tester);
      expect(_currentSubtitle(tester), '第二句同步字幕');
      session.players.first.emitCompleted();
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(find.text('第二句同步字幕'), findsNothing);
      expect(find.text('本章暂无同步字幕'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('audio-read-along-chapter')),
            )
            .data,
        '第二章',
      );
      nextSubtitles.complete(_nextTrack);
      await _flush(tester);
      expect(_currentSubtitle(tester), '下一章同步字幕');
      Navigator.of(
        tester.element(find.byKey(const Key('audio_subtitle_current'))),
      ).pop();
      await tester.pumpAndSettle();
      session.players.last.emitPosition(const Duration(seconds: 12));
      await _flush(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('subtitle failure is optional and does not interrupt playback', (
    tester,
  ) async {
    final session = _AudioSession(
      (_, _) async => throw FormatException('bad timeline'),
    );
    await _mount(tester, session.app());
    await _openReadAlong(tester);
    expect(find.text('本章暂无同步字幕'), findsOneWidget);
    expect(session.players.single.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a subtitle request may finish after the open reader is disposed',
    (tester) async {
      final subtitles = Completer<SubtitleTrack>();
      await _mount(tester, _AudioSession((_, _) => subtitles.future).app());
      await _openReadAlong(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      subtitles.complete(_track);
      await _flush(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('automatic next can be toggled twice in the same sheet', (
    tester,
  ) async {
    final session = _AudioSession((_, _) async => SubtitleTrack.empty);
    await _mount(tester, session.app());
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('audio-auto-next'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await _flush(tester);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(session.store.entry?['autoAdvance'], isFalse);
    await tester.tap(toggle);
    await _flush(tester);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(session.store.entry?['autoAdvance'], isTrue);
  });

  testWidgets(
    'an open more sheet enables automatic next when loading finishes',
    (tester) async {
      final source = Completer<AudioSource>();
      final session = _AudioSession(
        (_, _) async => SubtitleTrack.empty,
        sourceLoader: (_, {toneId}) => source.future,
      );
      await _mount(tester, session.app(), settle: false);
      await tester.tap(find.byTooltip('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final toggle = find.byKey(const ValueKey('audio-auto-next'));
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      source.complete(
        const AudioSource(
          itemId: 'c1',
          url: 'https://example.invalid/c1.mp3',
          toneId: '0',
        ),
      );
      await _flush(tester);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
      await tester.tap(toggle);
      await _flush(tester);
      expect(session.store.entry?['autoAdvance'], isFalse);
    },
  );

  testWidgets('an open more sheet updates its remaining sleep minutes', (
    tester,
  ) async {
    final session = _AudioSession((_, _) async => SubtitleTrack.empty);
    await _mount(tester, session.app());
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('定时关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 分钟后'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    String remaining() => tester.widget<Text>(find.textContaining('剩余 ')).data!;
    final before = remaining();
    await tester.pump(const Duration(seconds: 61));
    await _flush(tester);
    expect(remaining(), isNot(before));
    expect(remaining(), matches(RegExp(r'^剩余 1[34] 分钟$')));
  });

  testWidgets(
    'the final chapter end page stays reachable and opens its comments',
    (tester) async {
      final comments = <String>[];
      await _mountReader(tester, comments: comments);
      final state = tester.state<ReaderPagedViewState>(
        find.byType(ReaderPagedView),
      );
      unawaited(state.turnPage(1));
      await tester.pumpAndSettle();
      expect(find.text('本章完').hitTestable(), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('本章完').hitTestable(), findsOneWidget);
      unawaited(state.turnPage(1));
      await tester.pumpAndSettle();
      expect(find.text('本章完').hitTestable(), findsOneWidget);
      expect(find.text('已是最后一章'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-chapter-comments')));
      await tester.pumpAndSettle();
      expect(comments, ['c1:10000']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scroll auto turn moves the viewport then advances to the next chapter',
    (tester) async {
      await _mountReader(
        tester,
        scroll: true,
        chapterCount: 2,
        longFirstChapter: true,
      );
      await _startAutoTurn(tester);
      final controller = tester
          .widget<ListView>(find.byKey(const ValueKey('reader-paragraph-list')))
          .controller!;
      expect(controller.offset, 0);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(
        tester
            .widget<ReaderStatusBar>(find.byType(ReaderStatusBar))
            .chapterIndex,
        0,
      );
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReaderStatusBar>(find.byType(ReaderStatusBar))
            .chapterIndex,
        1,
      );
    },
  );

  for (final scroll in [false, true]) {
    testWidgets(
      '${scroll ? 'scroll' : 'paged'} auto turn stops at the end of the book',
      (tester) async {
        await _mountReader(tester, scroll: scroll);
        await _startAutoTurn(tester);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 8));
        await tester.pumpAndSettle();
        expect(find.text('已是最后一章'), findsNothing);
        if (!scroll) expect(find.text('本章完').hitTestable(), findsOneWidget);
        // A stopped timer lets this one tap open the controls. A running timer
        // consumes it merely to stop automatic reading.
        await _tapReaderCenter(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('reader-auto-turn')), findsOneWidget);
        expect(find.text('自动翻页'), findsOneWidget);
      },
    );
  }

  testWidgets('a six out of ten aggregate rating renders three filled stars', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DetailReviews(
            page: BookCommentPage(totalCount: 1),
            detail: BookDetail(score: '6'),
          ),
        ),
      ),
    );
    final stars = find.descendant(
      of: find.byKey(const Key('detail_score_card')),
      matching: find.byType(DetailStarRow),
    );
    expect(tester.widget<DetailStarRow>(stars).stars, 3);
    expect(find.text('6.0'), findsOneWidget);
  });
}

String? _currentSubtitle(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('audio_subtitle_current'))).data;

Future<void> _openReadAlong(WidgetTester tester) async {
  final entry = find.byKey(const Key('audio_read_along'));
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _mount(
  WidgetTester tester,
  Widget app, {
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(app);
  await _flush(tester);
  if (settle) await tester.pumpAndSettle();
}

Future<void> _mountReader(
  WidgetTester tester, {
  bool scroll = false,
  int chapterCount = 1,
  bool longFirstChapter = false,
  List<String>? comments,
}) async {
  SharedPreferences.setMockInitialValues({
    'reader_page_mode': scroll ? 'scroll' : 'paged',
    'reader_auto_turn_seconds': 3,
  });
  await _mount(
    tester,
    MaterialApp(
      home: ReaderPage(
        bookId: 'review-reader',
        title: '交叉审查回归',
        chapters: [
          Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
          if (chapterCount > 1)
            Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
        ],
        startIndex: 0,
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        chapterLoader: (chapter) async =>
            longFirstChapter && chapter.itemId == 'c1'
            ? List.generate(
                60,
                (i) => '第 $i 段。自动阅读应先移动正文，再切换到下一章节。',
              ).join('\n\n')
            : '这是一章只有一页的短正文。',
        ideasLoader: (_) async => const ChapterIdeas(
          paragraphs: [ParagraphIdeas(paraIndex: 10000, count: 3)],
        ),
        commentResolver: (id, paragraph, cursor) async {
          comments?.add('$id:${paragraph.paraIndex}');
          return const BookCommentPage();
        },
      ),
    ),
  );
}

Future<void> _tapReaderCenter(WidgetTester tester) async {
  final surface = tester.getRect(
    find.byKey(const ValueKey('reader-page-surface')),
  );
  await tester.tapAt(Offset(surface.center.dx, surface.bottom - 4));
}

Future<void> _startAutoTurn(WidgetTester tester) async {
  await _tapReaderCenter(tester);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('reader-auto-turn')));
  await tester.pumpAndSettle();
}

class _AudioSession {
  _AudioSession(this.subtitles, {this.sourceLoader});

  final SubtitleLoader subtitles;
  final Future<AudioSource> Function(String, {String? toneId})? sourceLoader;
  final store = ControlledReaderStore();
  final players = <ControlledNativePlayer>[];

  Widget app() => MaterialApp(
    home: AudioPage(
      bookId: 'review-audio',
      title: '听书交叉审查',
      chapters: [
        Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
        Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
      ],
      historyStore: store,
      sourceLoader:
          sourceLoader ??
          (id, {toneId}) async => AudioSource(
            itemId: id,
            url: 'https://example.invalid/$id.mp3',
            toneId: toneId ?? '0',
          ),
      voicesLoader: () async => const [],
      extrasLoader: (_) async => const AudioExtras(),
      subtitleLoader: subtitles,
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
    ),
  );
}
