import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/cached_books_page.dart';
import 'package:fqapp/services/book_txt_export.dart';
import 'package:fqapp/services/chapter_cache_store.dart';

import 'support/fakes.dart';

void main() {
  final first = Chapter(itemId: '1', title: '第一章', volumeName: '');
  final second = Chapter(itemId: '2', title: '第二章', volumeName: '');

  Future<_StubCacheStore> cachedBook() async {
    final cache = _StubCacheStore();
    await cache.saveBook(
      CachedBook(id: 'book-1', title: '测试书', chapters: [first]),
    );
    await cache.write(
      bookId: 'book-1',
      chapterId: '1',
      title: '第一章',
      text: '缓存正文',
    );
    return cache;
  }

  testWidgets('导出整本写进系统下载目录并回报路径', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = await cachedBook();
    final sink = _RecordingSink();
    await tester.pumpWidget(
      MaterialApp(
        home: CachedBooksPage(
          cacheStore: cache,
          readerStore: MemoryReaderStore(),
          exportDirectoryLoader: (bookId) async => [first, second],
          exportChapterLoader: (chapter) async => '正文${chapter.itemId}',
          exportSink: sink,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cached_book_export_book-1')));
    await tester.pumpAndSettle();

    expect(sink.calls.single.fileName, '测试书.txt');
    expect(sink.calls.single.text, '# 第一章\n正文1\n\n# 第二章\n正文2\n\n');
    expect(find.textContaining('已导出《测试书》2 章'), findsOneWidget);
    expect(find.textContaining('/sdcard/Download/测试书.txt'), findsOneWidget);
    // 行内其余操作没有被这次改动挤掉。
    expect(find.byTooltip('删除《测试书》缓存'), findsOneWidget);
  });

  testWidgets('导出中显示章节进度，再点一次即取消且不落盘', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = await cachedBook();
    final sink = _RecordingSink();
    final gate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: CachedBooksPage(
          cacheStore: cache,
          readerStore: MemoryReaderStore(),
          exportDirectoryLoader: (bookId) async => [first, second],
          exportChapterLoader: (chapter) async {
            await gate.future;
            return '正文${chapter.itemId}';
          },
          exportSink: sink,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final exportButton = find.byKey(const Key('cached_book_export_book-1'));
    await tester.tap(exportButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('导出 0/2 章'), findsOneWidget);
    expect(find.byTooltip('取消导出'), findsOneWidget);

    await tester.tap(exportButton);
    await tester.pump();

    expect(find.textContaining('已取消导出'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();

    expect(sink.calls, isEmpty);
    expect(find.text('导出 0/2 章'), findsNothing);
    expect(find.byTooltip('导出 TXT 到系统「下载」'), findsOneWidget);
  });

  testWidgets('上游取不到目录时报告失败而不是写出空书', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = await cachedBook();
    final sink = _RecordingSink();
    await tester.pumpWidget(
      MaterialApp(
        home: CachedBooksPage(
          cacheStore: cache,
          readerStore: MemoryReaderStore(),
          exportDirectoryLoader: (bookId) async => throw StateError('offline'),
          exportChapterLoader: (chapter) async => '正文',
          exportSink: sink,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cached_book_export_book-1')));
    await tester.pumpAndSettle();

    expect(sink.calls, isEmpty);
    expect(find.textContaining('目录获取失败'), findsOneWidget);
  });
}

class _RecordingSink implements TxtSink {
  final List<({String fileName, String text})> calls = [];

  @override
  Future<ExportTarget> saveText({
    required String fileName,
    required String text,
  }) async {
    calls.add((fileName: fileName, text: text));
    return ExportTarget(path: '/sdcard/Download/$fileName', isPublic: true);
  }
}

/// 只为这次导出用例存在的内存缓存门面：真实现要 Hive 盒子，这里只保留
/// 缓存页读取列表所需的 `books()` 与正文读写。
class _StubCacheStore extends ChapterCacheStore {
  final MemoryChapterCache memory = MemoryChapterCache();

  @override
  Future<String?> read({required String bookId, required String chapterId}) =>
      memory.read(bookId: bookId, chapterId: chapterId);

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async {
    await memory.write(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      pinned: pinned,
    );
    changes.value++;
  }

  @override
  Future<void> saveBook(CachedBook book) => memory.saveBook(book);

  @override
  Future<Set<String>> cachedChapterIds(String bookId) =>
      memory.cachedChapterIds(bookId);

  @override
  Future<List<CachedBookSummary>> books() async => [
    for (final book in memory.catalogs.values)
      if (memory.content[book.id]?.isNotEmpty ?? false)
        CachedBookSummary(
          book,
          ChapterCacheStats(
            chapterCount: memory.content[book.id]!.length,
            byteCount: 30,
          ),
        ),
  ];

  @override
  Future<void> clear({String? bookId}) async {
    if (bookId == null) {
      memory.content.clear();
      memory.catalogs.clear();
    } else {
      memory.content.remove(bookId);
      memory.catalogs.remove(bookId);
    }
    changes.value++;
  }
}
