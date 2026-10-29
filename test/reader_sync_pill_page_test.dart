import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/cue_index.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';

/// 阅读页上的同步胶囊行为：默认跟随、手动翻页、原进度、从本页听。
///
/// 对应官方 `d.java:285-320` 的底部按钮切换与
/// `AudioSyncReaderController.K()`（:768）/ `L()`（:702）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    ListeningSession.instance.clear();
    ListeningSession.instance.setFollowArmed(false);
  });

  tearDown(() {
    ListeningSession.instance.clear();
  });

  group('reader page', () {
    testWidgets('follows narration by default without pressing anything', (
      tester,
    ) async {
      await _mount(tester);
      expect(ListeningSession.instance.followArmed, isFalse);

      // 起播：官方 onPlayStart（d.java:143-151）把页面同步到朗读处。
      _seed(positionMs: 0, track: _track(), cue: '长句');
      await tester.pump(const Duration(milliseconds: 150));
      expect(ListeningSession.instance.followArmed, isTrue);
      expect(_pager(tester).pageIndex, 0);

      _seed(positionMs: 36000, track: _track(), cue: '长句');
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        _pager(tester).pageIndex,
        greaterThan(0),
        reason: '默认跟随应把页面带到正在读的那一页',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'a manually turned page stops following and shows the sync pill',
      (tester) async {
        await _mount(tester);
        _seed(positionMs: 0, track: _shortTrack(), cue: _sentence);
        await tester.pump(const Duration(milliseconds: 150));
        expect(
          find.byKey(const ValueKey('reader_player_pill')),
          findsOneWidget,
        );

        await _tapSide(tester, 1);
        await tester.pumpAndSettle();

        expect(_pager(tester).pageIndex, 1);
        expect(
          ListeningSession.instance.followArmed,
          isFalse,
          reason: '手动翻页退出跟随，等「原进度」恢复',
        );
        expect(find.byKey(const ValueKey('reader_sync_pill')), findsOneWidget);
        expect(find.byKey(const ValueKey('reader_player_pill')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('原进度 returns to the narration and follows again', (
      tester,
    ) async {
      await _mount(tester);
      final layout = _pager(tester).layout;
      _seed(positionMs: 0, track: _shortTrack(), cue: _sentence);
      await tester.pump(const Duration(milliseconds: 150));
      await _tapSide(tester, 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reader_sync_return_original')),
      );
      await tester.pumpAndSettle();

      expect(_pager(tester).pageIndex, 0, reason: '「原进度」回到正在读的位置');
      expect(ListeningSession.instance.followArmed, isTrue);

      // 播放位置继续前进，跟随必须马上跟上（闩锁已清）。
      _seed(positionMs: 36000, track: _shortTrack(), cue: _lastParagraph);
      await tester.pump(const Duration(milliseconds: 250));
      final track = _shortTrack();
      final span = CueIndex.build(
        layout: layout,
        track: track,
      ).spanAtPositionMs(36000)!;
      final target = layout.pageForOffset(span.spokenOffset(36000));
      expect(target, greaterThan(0));
      expect(_pager(tester).pageIndex, target);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('从本页听 restarts from this page with the current tone', (
      tester,
    ) async {
      await _mountOnline(tester);
      // 已经在这本书里暂停：高亮不在屏内，同步胶囊可见。
      ListeningSession.instance.update(
        bookId: 'reader-test',
        chapterId: 'c1',
        chapterTitle: '第一章',
        position: Duration.zero,
        duration: const Duration(seconds: 60),
        playing: false,
        toneId: 'narrator-7',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader_sync_pill')), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reader_sync_listen_from_here')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AudioPage), findsOneWidget);
      final audio = tester.widget<AudioPage>(find.byType(AudioPage));
      // 本页第一段带 <span start_time="4200">。
      expect(audio.startPosition, const Duration(milliseconds: 4200));
      expect(audio.initialToneId, 'narrator-7');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

final _surface = find.byKey(const ValueKey('reader-page-surface'));

ReaderPagedView _pager(WidgetTester tester) =>
    tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));

const _sentence = '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗，看见远处的云正慢慢越过山脊。';

String _longParagraph() => List.generate(40, (_) => _sentence).join();

const _lastParagraph = '最后一段很短。';

SubtitleTrack _track() => SubtitleTrack([
  SubtitleCue(startMs: 0, text: _longParagraph().substring(0, 1200)),
  SubtitleCue(startMs: 40000, text: _lastParagraph),
]);

/// 一句短的：高亮只占第 0 页，手动翻一页就离开屏内。
SubtitleTrack _shortTrack() => SubtitleTrack([
  SubtitleCue(startMs: 0, text: _sentence),
  SubtitleCue(startMs: 30000, text: _lastParagraph),
]);

final _chapters = [
  Chapter(itemId: 'c1', title: '第一章 山间来信', volumeName: '正文'),
  Chapter(itemId: 'c2', title: '第二章 远山', volumeName: '正文'),
];

String _text(Chapter chapter) {
  if (chapter.itemId == 'c2') {
    return parseChapterContent(
      '<header><div class="tt-title">${chapter.title}</div></header><article>'
      '${List.generate(6, (i) => '<p idx="$i">$_sentence</p>').join()}'
      '</article>',
    ).toCacheText();
  }
  return parseChapterContent(
    '<header><div class="tt-title">${chapter.title}</div></header><article>'
    '<p idx="0">${_longParagraph()}</p>'
    '<p idx="1">$_lastParagraph</p>'
    '</article>',
  ).toCacheText();
}

Widget _app() => MaterialApp(
  home: ReaderPage(
    bookId: 'b1',
    title: '山川来信',
    chapters: _chapters,
    startIndex: 0,
    localOnly: true,
    readerStore: MemoryReaderStore(),
    chapterCache: MemoryChapterCache(),
    chapterLoader: (chapter) async => _text(chapter),
    readerDevice: _NullDevice(),
  ),
);

Future<void> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(320, 480));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

/// 线上书：章节自带 `<span start_time>`，用来验「从本页听」的锚点与音色。
Widget _onlineApp() => MaterialApp(
  home: ReaderPage(
    bookId: 'reader-test',
    title: '测试书籍',
    chapters: [Chapter(itemId: 'c1', title: '第一章', volumeName: '正文')],
    startIndex: 0,
    readerStore: MemoryReaderStore(),
    chapterCache: MemoryChapterCache(),
    chapterLoader: (_) async => parseChapterContent(
      '<header><div class="tt-title">第一章</div></header><article>'
      '<p idx="0"><span start_time="4200">第一段正文。</span></p>'
      '<p idx="1">第二段正文。</p>'
      '</article>',
    ).toCacheText(),
    readerDevice: _NullDevice(),
  ),
);

Future<void> _mountOnline(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_onlineApp());
  await tester.pumpAndSettle();
}

Future<void> _tapSide(WidgetTester tester, int direction) async {
  final rect = tester.getRect(_surface);
  await tester.tapAt(
    Offset(rect.left + rect.width * (direction > 0 ? .9 : .1), rect.center.dy),
  );
  await tester.pumpAndSettle();
}

/// 直接把会话摆成某个状态（播放器那边写入的等价物）。
void _seed({
  required int positionMs,
  required SubtitleTrack track,
  required String cue,
}) {
  ListeningSession.instance.update(
    bookId: 'b1',
    chapterId: 'c1',
    chapterTitle: '第一章 山间来信',
    position: Duration(milliseconds: positionMs),
    duration: const Duration(seconds: 60),
    playing: true,
    subtitles: track,
    cue: cue,
  );
}

class _NullDevice extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 9, 10, 21, 16),
    battery: 64,
    systemBrightness: .45,
  );
  @override
  Future<void> suspend() async {}
  @override
  Future<void> close() async {}
}
