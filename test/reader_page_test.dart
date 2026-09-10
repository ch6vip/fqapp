import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('a long chapter error can be scrolled to retry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var attempts = 0;
    await tester.pumpWidget(
      _readerApp(
        chapterLoader: (chapter) async {
          if (chapter.itemId == 'chapter-1' && ++attempts == 1) {
            throw StateError(List.filled(60, '正文请求失败，连接中断。').join('\n'));
          }
          return _shortChapterLoader(chapter);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试').hitTestable(), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('这是 第一章 的正文。'), findsOneWidget);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  for (final loadState in ['pending', 'failed', 'not yet displayed']) {
    testWidgets('leaving a $loadState chapter preserves saved progress', (
      tester,
    ) async {
      final pending = Completer<String>();
      final saved = <String, dynamic>{
        'id': 'reader-test',
        'chapterId': 'chapter-2',
        'episode': 1,
        'position': 300.0,
        'maxScroll': 900.0,
        'progress': 4 / 9,
      };
      final store = _FakeReaderStore()..entry = Map.of(saved);
      await tester.pumpWidget(
        _readerApp(readerStore: store, chapterLoader: (_) => pending.future),
      );
      await tester.pump();
      if (loadState == 'failed') {
        pending.completeError(StateError('chapter unavailable'));
        await tester.pumpAndSettle();
        expect(find.textContaining('chapter unavailable'), findsOneWidget);
      } else if (loadState == 'not yet displayed') {
        pending.complete('A chapter that has not been displayed.');
        await tester.idle();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      }

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.idle();
      expect(store.entry, saved);
      await tester.pumpWidget(const SizedBox.shrink());
      if (!pending.isCompleted) pending.complete('A chapter opened too late.');
      await tester.pumpAndSettle();
      expect(store.entry, saved);
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  }

  testWidgets('a failed chapter switch preserves the last displayed position', (
    tester,
  ) async {
    final nextChapter = Completer<String>();
    final store = _FakeReaderStore();
    await tester.pumpWidget(
      _readerApp(
        readerStore: store,
        chapterLoader: (chapter) => chapter.itemId == 'chapter-1'
            ? _longChapterLoader(chapter)
            : nextChapter.future,
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    controller.jumpTo(300);
    await tester.pump();
    await _openMenu(tester);
    await tester.tap(find.byTooltip('下一章'));
    await tester.pump();
    final saved = Map<String, dynamic>.of(store.entry!);
    expect(saved['chapterId'], 'chapter-1');
    expect(saved['position'], 300);
    await tester.pump(const Duration(seconds: 1));
    expect(store.entry, saved);

    nextChapter.completeError(StateError('next chapter unavailable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('next chapter unavailable'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(store.entry, saved);
    expect(tester.takeException(), isNull);
  });

  for (final operation in ['read history', 'add history', 'update progress']) {
    testWidgets('a $operation failure keeps reading and navigation usable', (
      tester,
    ) async {
      final store = _FakeReaderStore()
        ..failHistoryRead = operation == 'read history'
        ..failHistoryWrite = operation == 'add history';
      await tester.pumpWidget(_readerApp(readerStore: store));
      await tester.pumpAndSettle();
      expect(find.textContaining('这是 第一章 的正文。'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      if (operation == 'update progress') store.failHistoryWrite = true;
      await _openMenu(tester);
      await tester.tap(find.byTooltip('下一章'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这是 第二章 的正文。'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('restoration finishes before history is saved', (tester) async {
    final store = _FakeReaderStore()
      ..entry = {
        'id': 'reader-test',
        'chapterId': 'chapter-1',
        'episode': 0,
        'position': 300.0,
        'maxScroll': 900.0,
        'progress': 1 / 9,
      };
    await tester.pumpWidget(
      _readerApp(readerStore: store, chapterLoader: _longChapterLoader),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(controller.offset, greaterThan(0));
    expect(store.entry?['position'], controller.offset);
    expect(store.entry?['progress'], closeTo(1 / 9, .001));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'novel reading never interprets legacy audio seconds as scroll position',
    (tester) async {
      final store = _FakeReaderStore()
        ..entry = {
          'id': 'reader-test',
          'kind': 'audio',
          'chapterId': 'chapter-1',
          'episode': 0,
          'position': 300.0,
          'maxScroll': 900.0,
        };
      await tester.pumpWidget(
        _readerApp(readerStore: store, chapterLoader: _longChapterLoader),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<ListView>(find.byType(ListView))
          .controller!;
      expect(controller.offset, 0);
      expect(store.entry?['kind'], 'book');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a delayed history write cannot overwrite later exit progress', (
    tester,
  ) async {
    final historyWrite = Completer<void>();
    final store = _FakeReaderStore()..historyWriteDelay = historyWrite.future;
    await tester.pumpWidget(
      _readerApp(readerStore: store, chapterLoader: _longChapterLoader),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-page-surface')), findsOneWidget);
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    controller.jumpTo(300);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    historyWrite.complete();
    await tester.pumpAndSettle();
    expect(store.entry?['chapterId'], 'chapter-1');
    expect(store.entry?['position'], 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening waits for the departing reader to save its position', (
    tester,
  ) async {
    final store = _FakeReaderStore();
    await tester.pumpWidget(
      _readerApp(readerStore: store, chapterLoader: _longChapterLoader),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    final exitWrite = Completer<void>();
    store.historyWriteDelay = exitWrite.future;
    controller.jumpTo(300);
    await tester.pumpWidget(const SizedBox.shrink());
    store.historyWriteDelay = null;

    await tester.pumpWidget(
      _readerApp(readerStore: store, chapterLoader: _longChapterLoader),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-page-surface')), findsNothing);
    exitWrite.complete();
    await tester.pumpAndSettle();
    final reopened = tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(reopened.offset, greaterThan(200));
    reopened.jumpTo(700);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(store.entry?['position'], 700);
  });

  testWidgets('late prefetch cannot recreate a cache cleared after leaving', (
    tester,
  ) async {
    final cache = MemoryChapterCache();
    final pending = Completer<String>();
    await tester.pumpWidget(
      _readerApp(
        chapterCache: cache,
        chapterLoader: (chapter) => chapter.itemId == 'chapter-1'
            ? _shortChapterLoader(chapter)
            : pending.future,
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    cache.content.clear();
    cache.catalogs.clear();
    pending.complete('A chapter fetched after the reader was closed.');
    await tester.pumpAndSettle();
    expect(cache.content, isEmpty);
    expect(cache.catalogs, isEmpty);
  });

  testWidgets(
    'cached chapters open offline and directory marks saved chapters',
    (tester) async {
      final cache = MemoryChapterCache();
      for (final chapter in _chapters) {
        await cache.write(
          bookId: 'reader-test',
          chapterId: chapter.itemId,
          title: chapter.title,
          text: '${chapter.title}的离线正文',
        );
      }
      final requests = <String>[];
      await tester.pumpWidget(
        _readerApp(
          chapterCache: cache,
          chapterLoader: (chapter) async {
            requests.add(chapter.itemId);
            throw StateError('网络断开');
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('第一章的离线正文'), findsOneWidget);
      expect(requests, [_chapters.first.itemId]);
      await _openMenu(tester);
      await tester.tap(find.text('目录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('已缓存'), findsNWidgets(3));
      await tester.tap(
        find.descendant(of: find.byType(ListTile), matching: find.text('尾声')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('尾声的离线正文'), findsOneWidget);
      expect(requests, [_chapters.first.itemId, _chapters.last.itemId]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final offline in [false, true]) {
    testWidgets(
      'paragraphs indent only the first line and wrap naturally (offline: $offline)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const first = '“尉迟，南宫，欧阳，上官，司马，东方……”';
        const second = '黎问音站在学校门口的优秀学生公告栏那，碎碎念着这些学生的姓氏，就明白了。';
        final cache = MemoryChapterCache();
        if (offline) {
          for (final chapter in _chapters) {
            await cache.write(
              bookId: 'reader-test',
              chapterId: chapter.itemId,
              title: chapter.title,
              text: '${chapter.title}\r\n　　$first\r\n\r\n  $second',
            );
          }
        }
        final requests = <String>[];
        await tester.pumpWidget(
          _readerApp(
            chapterCache: cache,
            textScaler: TextScaler.linear(offline ? 1.3 : 1),
            chapterLoader: (chapter) async {
              requests.add(chapter.itemId);
              if (offline) throw StateError('网络断开');
              return normalizeChapterText(
                '<h1>${chapter.title}</h1><div>　　$first</div>'
                '<div>  $second</div>',
              );
            },
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('第一章'), findsNWidgets(2));
        expect(find.textContaining(first), findsOneWidget);
        expect(find.textContaining(second), findsOneWidget);
        if (offline) expect(requests, [_chapters.first.itemId]);
        final firstParagraph = find.byKey(const ValueKey('reader-paragraph-0'));
        final secondParagraph = find.byKey(
          const ValueKey('reader-paragraph-1'),
        );
        final firstRender = _paragraphRender(tester, firstParagraph);
        final contentBoxes = firstRender.getBoxesForSelection(
          const TextSelection(baseOffset: 1, extentOffset: first.length + 1),
        );
        expect(contentBoxes.length, greaterThan(1));
        expect(
          contentBoxes.first.left,
          closeTo(18 * (offline ? 1.3 : 1) * 2, 2),
        );
        expect(contentBoxes[1].left, closeTo(0, .01));
        expect(contentBoxes.last.right, lessThan(firstRender.size.width - 9));
        expect(
          tester.getRect(secondParagraph).top -
              tester.getRect(firstParagraph).bottom,
          closeTo(12, .01),
        );

        final secondRender = _paragraphRender(tester, secondParagraph);
        const selection = TextSelection(
          baseOffset: 1,
          extentOffset: second.length + 1,
        );
        final wideBoxes = secondRender.getBoxesForSelection(selection);
        final wideLineEnd = secondRender.getPositionForOffset(
          Offset(
            secondRender.size.width,
            (wideBoxes.first.top + wideBoxes.first.bottom) / 2,
          ),
        );
        await tester.binding.setSurfaceSize(const Size(280, 900));
        await tester.pumpAndSettle();
        final narrowRender = _paragraphRender(tester, secondParagraph);
        final narrowBoxes = narrowRender.getBoxesForSelection(selection);
        final narrowLineEnd = narrowRender.getPositionForOffset(
          Offset(
            narrowRender.size.width,
            (narrowBoxes.first.top + narrowBoxes.first.bottom) / 2,
          ),
        );
        expect(narrowBoxes.length, greaterThanOrEqualTo(wideBoxes.length));
        expect(narrowLineEnd.offset, lessThan(wideLineEnd.offset));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('right tap scrolls one screen before changing chapter', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeReaderStore();
    await tester.pumpWidget(
      _readerApp(chapterLoader: _longChapterLoader, readerStore: store),
    );
    await tester.pumpAndSettle();

    final listView = tester.widget<ListView>(find.byType(ListView));
    final controller = listView.controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(controller.offset, 0);

    final readingSurface = find.byKey(const ValueKey('reader-page-surface'));
    final surfaceRect = tester.getRect(readingSurface);
    final rightSide = Offset(
      surfaceRect.left + surfaceRect.width * 0.9,
      surfaceRect.top + surfaceRect.height * 0.5,
    );

    await tester.tapAt(rightSide);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-toolbar')), findsNothing);
    expect(controller.offset, greaterThan(0));
    expect(find.text('第二章'), findsNothing);
    expect(store.entry?['episode'], 0);

    for (var attempt = 0; attempt < 20; attempt++) {
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      if ((controller.position.maxScrollExtent - controller.offset).abs() < 1) {
        break;
      }
    }
    expect(
      controller.position.maxScrollExtent - controller.offset,
      lessThan(2),
    );
    await tester.tapAt(rightSide);
    await tester.pumpAndSettle();

    expect(find.text('第二章'), findsWidgets);
    expect(store.entry?['episode'], 1);
  });

  testWidgets('directory locates, filters, reverses and opens chapters', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = _FakeReaderStore();
    await tester.pumpWidget(_readerApp(readerStore: store));
    await tester.pumpAndSettle();
    await _openMenu(tester);
    await tester.tap(find.text('目录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('目录 · 3 章'), findsOneWidget);
    final selectedTiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .where((tile) => tile.selected)
        .toList(growable: false);
    expect(selectedTiles, hasLength(1));
    expect((selectedTiles.single.title as Text).data, '第一章');

    await tester.enterText(find.byType(TextField), '尾声');
    await tester.pump();
    final filteredTiles = tester.widgetList<ListTile>(find.byType(ListTile));
    expect(filteredTiles, hasLength(1));
    expect((filteredTiles.single.title as Text).data, '尾声');

    await tester.tap(find.byTooltip('清空'));
    await tester.pump();
    await tester.tap(find.byTooltip('切换为倒序'));
    await tester.pump();

    final firstChapter = find.descendant(
      of: find.byType(ListTile),
      matching: find.text('第一章'),
    );
    final lastChapter = find.descendant(
      of: find.byType(ListTile),
      matching: find.text('尾声'),
    );
    expect(
      tester.getCenter(lastChapter).dy,
      lessThan(tester.getCenter(firstChapter).dy),
    );

    await tester.tap(lastChapter);
    await tester.pumpAndSettle();
    expect(find.text('尾声'), findsWidgets);
    expect(store.entry?['episode'], 2);
  });

  testWidgets('appearance sheet fits a narrow screen with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_readerApp(textScaler: const TextScaler.linear(2)));
    await tester.pumpAndSettle();
    await _openMenu(tester);
    await tester.ensureVisible(find.text('排版'));
    await tester.tap(find.text('排版'));
    await tester.pumpAndSettle();

    expect(find.text('排版设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
  );
  await tester.pumpAndSettle();
}

RenderParagraph _paragraphRender(WidgetTester tester, Finder paragraph) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: paragraph, matching: find.byType(RichText)),
    );

Widget _readerApp({
  ChapterTextLoader? chapterLoader,
  ReaderStore? readerStore,
  ChapterCache? chapterCache,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: ReaderPage(
      bookId: 'reader-test',
      title: '测试书籍',
      chapters: _chapters,
      startIndex: 0,
      chapterLoader: chapterLoader ?? _shortChapterLoader,
      readerStore: readerStore ?? _FakeReaderStore(),
      chapterCache: chapterCache ?? MemoryChapterCache(),
    ),
  );
}

final _chapters = [
  Chapter(itemId: 'chapter-1', title: '第一章', volumeName: '正文'),
  Chapter(itemId: 'chapter-2', title: '第二章', volumeName: '正文'),
  Chapter(itemId: 'chapter-3', title: '尾声', volumeName: '正文'),
];

Future<String> _shortChapterLoader(Chapter chapter) async =>
    '${chapter.title}\n这是 ${chapter.title} 的正文。';

Future<String> _longChapterLoader(Chapter chapter) async {
  if (chapter.itemId != 'chapter-1') return _shortChapterLoader(chapter);
  return List.generate(
    120,
    (index) => '第 ${index + 1} 段。这是一段用于验证翻页行为的测试正文。',
  ).join('\n\n');
}

class _FakeReaderStore implements ReaderStore {
  Map<String, dynamic>? entry;
  double readSeconds = 0;
  bool failHistoryRead = false;
  bool failHistoryWrite = false;
  Future<void>? historyWriteDelay;

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    if (failHistoryRead) throw StateError('history read failed');
    return entry == null ? null : Map<String, dynamic>.from(entry!);
  }

  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
    if (failHistoryWrite) throw StateError('history write failed');
    await historyWriteDelay;
    entry = Map<String, dynamic>.from(value);
  }

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {
    if (entry == null) return;
    entry = {
      ...entry!,
      'episode': episode,
      'progress': progress,
      'chapterId': ?chapterId,
      'position': ?position,
      'maxScroll': ?maxScroll,
    };
  }

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {
    readSeconds += seconds;
  }
}
