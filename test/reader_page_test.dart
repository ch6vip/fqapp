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

  setUp(() => SharedPreferences.setMockInitialValues({}));

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
      expect(requests, isEmpty);
      await tester.tap(find.text('目录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('已缓存'), findsNWidgets(3));
      await tester.tap(
        find.descendant(of: find.byType(ListTile), matching: find.text('尾声')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('尾声的离线正文'), findsOneWidget);
      expect(requests, isEmpty);
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
        if (offline) expect(requests, isEmpty);
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

    expect(find.byType(AppBar), findsOneWidget);
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
    await tester.tap(find.text('排版'));
    await tester.pumpAndSettle();

    expect(find.text('排版设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
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

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    return entry == null ? null : Map<String, dynamic>.from(entry!);
  }

  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
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
