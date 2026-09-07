import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/cached_books_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('repeated taps while history loads open only one reader', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final history = _DelayedHistoryStore();
    final cache = _ManagedMemoryCache();
    await cache.saveBook(
      CachedBook(
        id: 'cached',
        title: '离线测试书',
        chapters: [Chapter(itemId: '1', title: '缓存章节', volumeName: '')],
      ),
    );
    await cache.write(
      bookId: 'cached',
      chapterId: '1',
      title: '缓存章节',
      text: '缓存正文',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CachedBooksPage(cacheStore: cache, readerStore: history),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('离线测试书'));
    await tester.tap(find.text('离线测试书'));
    history.pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage, skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scenario in [
    (
      label: 'numeric chapter ID',
      saved: <String, dynamic>{'chapterId': 2, 'episode': 0},
      chapter: '2',
    ),
    (
      label: 'damaged episode',
      saved: <String, dynamic>{'episode': 'invalid'},
      chapter: '1',
    ),
    (
      label: 'non-finite episode',
      saved: <String, dynamic>{'episode': double.nan},
      chapter: '1',
    ),
    (label: 'unavailable history', saved: null, chapter: '1'),
  ]) {
    testWidgets('offline reading tolerates ${scenario.label}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = _ManagedMemoryCache();
      final book = CachedBook(
        id: 'cached',
        title: '离线测试书',
        chapters: [
          for (var index = 1; index <= 2; index++)
            Chapter(itemId: '$index', title: '缓存章节$index', volumeName: ''),
        ],
      );
      await cache.saveBook(book);
      for (final chapter in book.chapters) {
        await cache.write(
          bookId: book.id,
          chapterId: chapter.itemId,
          title: chapter.title,
          text: '离线正文${chapter.itemId}',
        );
      }
      final history = scenario.saved == null
          ? _UnreadableHistoryStore()
          : MemoryReaderStore(entry: scenario.saved);
      await tester.pumpWidget(
        MaterialApp(
          home: CachedBooksPage(cacheStore: cache, readerStore: history),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线测试书'));
      await tester.pumpAndSettle();
      expect(find.textContaining('离线正文${scenario.chapter}'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'offline library opens cached content and clears it without history loss',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = _ManagedMemoryCache();
      await cache.saveBook(
        CachedBook(
          id: 'cached',
          title: '离线测试书',
          chapters: [Chapter(itemId: '1', title: '缓存章节', volumeName: '')],
        ),
      );
      await cache.write(
        bookId: 'cached',
        chapterId: '1',
        title: '缓存章节',
        text: '这段正文来自磁盘缓存',
      );
      final history = MemoryReaderStore(
        entry: {
          'id': 'cached',
          'chapterId': '1',
          'episode': 0,
          'position': 0.0,
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CachedBooksPage(cacheStore: cache, readerStore: history),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线测试书'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这段正文来自磁盘缓存'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除《离线测试书》缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无缓存章节'), findsOneWidget);
      expect(history.entry?['chapterId'], '1');
      expect(await cache.cachedChapterIds('cached'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _UnreadableHistoryStore extends MemoryReaderStore {
  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async =>
      throw StateError('History unavailable');
}

class _DelayedHistoryStore extends MemoryReaderStore {
  final pending = Completer<void>();

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    await pending.future;
    return entry;
  }
}

class _ManagedMemoryCache extends ChapterCacheStore {
  final memory = MemoryChapterCache();

  @override
  Future<String?> read({required String bookId, required String chapterId}) =>
      memory.read(bookId: bookId, chapterId: chapterId);

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
  }) async {
    await memory.write(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
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
