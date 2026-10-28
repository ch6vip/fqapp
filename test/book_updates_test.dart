import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/book_open_preferences.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';

final _chapters = [
  Chapter(itemId: '1', title: '第一章', volumeName: ''),
  Chapter(itemId: '2', title: '第二章', volumeName: ''),
  Chapter(itemId: '3', title: '第三章', volumeName: ''),
];
final _book = MediaItem(
  id: 'updated-book',
  title: '连载测试',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);

void main() {
  setUp(
    () =>
        SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'}),
  );

  testWidgets('更新目录按章节 ID 保留当前章节和滚动位置，并保存新目录', (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final cache = MemoryChapterCache();
    final history = MemoryReaderStore();
    var chapters = _chapters.take(2).toList();
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return ReaderPage(
              bookId: _book.id,
              title: _book.title,
              chapters: chapters,
              startIndex: 1,
              readerStore: history,
              chapterCache: cache,
              chapterLoader: (chapter) async =>
                  List.filled(100, '${chapter.title}的测试正文。').join('\n\n'),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    controller.jumpTo(300);
    await tester.pump();
    update(
      () => chapters = [
        Chapter(itemId: 'preface', title: '序言', volumeName: ''),
        ..._chapters,
      ],
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('第二章的测试正文。'), findsWidgets);
    expect(controller.offset, 300);
    expect(
      (await cache.savedCatalogue(_book.id))!.chapters.map((c) => c.itemId),
      ['preface', '1', '2', '3'],
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(history.entry?['chapterId'], '2');
    expect(history.entry?['episode'], 2);
    expect(history.entry?['chapterCount'], 4);
  });

  group('书架更新提示', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('fqapp-updates-');
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
    });
    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    for (final layout in [0, 1, 2]) {
      testWidgets('版式 $layout 显示新增章节，阅读新目录后清除更新提示', (tester) async {
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        SharedPreferences.setMockInitialValues({'bookshelf_layout': layout});
        await tester.runAsync(() async {
          await ShelfStore.instance.add(_book);
          await LibraryStore.instance.addHistory({
            'id': _book.id,
            'kind': 'book',
            'title': _book.title,
            'chapterId': '2',
            'episode': 1,
            'chapterCount': 2,
            'progress': 1.0,
          });
        });
        final cache = MemoryChapterCache();
        await cache.saveBook(
          CachedBook(id: _book.id, title: _book.title, chapters: _chapters),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryPage(
              cacheStore: cache,
              connectivity: () async => (online: false, metered: false),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('更新'), findsWidgets);
        expect(find.text('共2章·已读完'), findsNothing);
        await tester.runAsync(
          () => LibraryStore.instance.addHistory({
            'id': _book.id,
            'kind': 'book',
            'title': _book.title,
            'chapterId': '2',
            'episode': 1,
            'chapterCount': 3,
            'progress': 0.5,
          }),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('更新'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('联网检测新增章节，不等待打开详情页，并在返回前台时重查', (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await _seedShelf(tester);
      var count = 2;
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(
            cacheStore: MemoryChapterCache(),
            connectivity: () async => (online: true, metered: false),
            chapterCountLoader: (_) async => count,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('共2章·已读完'), findsOneWidget);
      expect(find.textContaining('更新'), findsNothing);
      count = 3;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsOneWidget);
      expect(find.text('共2章·已读完'), findsNothing);
    });

    testWidgets('书架点击封面会把后台新目录交给阅读器', (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      BookOpenPreferences.instance.resetForTest();
      await _seedShelf(tester);
      final cache = MemoryChapterCache();
      await cache.saveBook(
        CachedBook(
          id: _book.id,
          title: _book.title,
          chapters: _chapters.take(2).toList(),
        ),
      );
      for (final chapter in _chapters) {
        await cache.write(
          bookId: _book.id,
          chapterId: chapter.itemId,
          title: chapter.title,
          text: '${chapter.title}的缓存正文。' * 100,
        );
      }
      final pending = Completer<List<Chapter>>();
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(
            cacheStore: cache,
            readerStore: MemoryReaderStore(
              entry: {
                'id': _book.id,
                'kind': 'book',
                'chapterId': '2',
                'episode': 1,
              },
            ),
            connectivity: () async => (online: true, metered: false),
            directoryLoader: (_) => pending.future,
            chapterCountLoader: (_) async => 3,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsOneWidget);
      await tester.tap(find.text(_book.title));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).chapters,
        hasLength(2),
      );
      pending.complete(_chapters);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).chapters,
        hasLength(3),
      );
      expect(find.textContaining('第二章的缓存正文'), findsWidgets);
    });

    testWidgets('离线或目录未增加时不误报更新，旧缓存不降低已知总章数', (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await _seedShelf(tester);
      final cache = MemoryChapterCache();
      await cache.saveBook(
        CachedBook(
          id: _book.id,
          title: _book.title,
          chapters: [_chapters.first],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(
            cacheStore: cache,
            connectivity: () async => (online: false, metered: false),
            chapterCountLoader: (_) async => 3,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('更新'), findsNothing);
      expect(find.text('共2章·已读完'), findsOneWidget);
    });

    testWidgets('缺少旧总章数的历史不把已有章节误报为新增', (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await _seedShelf(tester);
      await tester.runAsync(
        () => LibraryStore.instance.addHistory({
          'id': _book.id,
          'kind': 'book',
          'title': _book.title,
          'chapterId': '2',
          'episode': 1,
          'progress': 0.5,
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(
            cacheStore: MemoryChapterCache(),
            connectivity: () async => (online: true, metered: false),
            chapterCountLoader: (_) async => 3,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('更新'), findsNothing);
      expect(find.textContaining('共3章'), findsOneWidget);
    });

    testWidgets('再次检测失败时保留已经发现的更新，不被旧缓存覆盖', (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await _seedShelf(tester);
      final cache = MemoryChapterCache();
      await cache.saveBook(
        CachedBook(
          id: _book.id,
          title: _book.title,
          chapters: _chapters.take(2).toList(),
        ),
      );
      var attempt = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(
            cacheStore: cache,
            connectivity: () async => (online: true, metered: false),
            chapterCountLoader: (_) async {
              if (++attempt > 1) throw StateError('offline');
              return 3;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsOneWidget);
    });

    testWidgets('单本检测失败不妨碍其他书籍更新，也不丢失阅读进度', (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await _seedShelf(tester);
      await tester.runAsync(() async {
        await ShelfStore.instance.add(
          MediaItem(
            id: 'failing',
            title: '检测失败的书',
            cover: '',
            author: '',
            badge: '',
            ep: '',
            kind: 'book',
          ),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(
            cacheStore: MemoryChapterCache(),
            connectivity: () async => (online: true, metered: false),
            chapterCountLoader: (id) async {
              if (id == 'failing') throw StateError('network unavailable');
              return 3;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsOneWidget);
      expect(find.text('检测失败的书'), findsOneWidget);
      expect(LibraryStore.instance.historySnapshot().single['chapterId'], '2');
      expect(tester.takeException(), isNull);
    });

    testWidgets('下拉可重新检查更新，请求返回时已移除的书不会重新加入', (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await _seedShelf(tester);
      final pending = Completer<int>();
      var attempt = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(
            cacheStore: MemoryChapterCache(),
            connectivity: () async => (online: true, metered: false),
            chapterCountLoader: (_) =>
                ++attempt == 1 ? Future.value(2) : pending.future,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final refresh = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator),
      );
      final completion = refresh.show();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
        () => ShelfStore.instance.removeKeys([ShelfStore.keyOf(_book)]),
      );
      pending.complete(3);
      await tester.pumpAndSettle();
      await completion;
      expect(find.text(_book.title), findsNothing);
      expect(ShelfStore.instance.records(), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> _seedShelf(WidgetTester tester) => tester.runAsync(() async {
  await ShelfStore.instance.add(_book);
  await LibraryStore.instance.addHistory({
    'id': _book.id,
    'kind': 'book',
    'title': _book.title,
    'chapterId': '2',
    'episode': 1,
    'chapterCount': 2,
    'progress': 1.0,
  });
});
