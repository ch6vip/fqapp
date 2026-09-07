import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('chapters evicted during a download are fetched again', (
    tester,
  ) async {
    final cache = _EvictingCache();
    await cache.write(
      bookId: 'book',
      chapterId: '3',
      title: '第三章',
      text: '旧正文',
    );
    final requested = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChapterCacheSheet(
            book: CachedBook(
              id: 'book',
              title: '测试小说',
              chapters: [
                for (var index = 1; index <= 3; index++)
                  Chapter(itemId: '$index', title: '第$index章', volumeName: ''),
              ],
            ),
            currentIndex: 0,
            cache: cache,
            loader: (chapter) async {
              requested.add(chapter.itemId);
              return '正文${chapter.itemId}';
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存后 2 章'));
    await tester.pumpAndSettle();
    expect(requested, ['2', '3']);
    expect(await cache.cachedChapterIds('book'), {'2', '3'});
    expect(find.textContaining('缓存完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'completed download stores following text and the offline catalog',
    (tester) async {
      final cache = MemoryChapterCache();
      final book = CachedBook(
        id: 'downloaded',
        title: '下载测试',
        chapters: [
          for (var i = 1; i <= 3; i++)
            Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChapterCacheSheet(
              book: book,
              currentIndex: 0,
              cache: cache,
              loader: (chapter) async => '正文${chapter.itemId}',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 2 章'));
      await tester.pumpAndSettle();
      expect(await cache.cachedChapterIds('downloaded'), {'2', '3'});
      expect(cache.catalogs['downloaded']!.chapters, hasLength(3));
      expect(find.textContaining('缓存完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'downloads following chapters, skips cached text, and stops late saves',
    (tester) async {
      final cache = MemoryChapterCache();
      await cache.write(
        bookId: 'book',
        chapterId: '2',
        title: '第二章',
        text: '已缓存',
      );
      final pending = Completer<String>();
      final requested = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChapterCacheSheet(
              book: CachedBook(
                id: 'book',
                title: '测试小说',
                chapters: [
                  for (var i = 1; i <= 3; i++)
                    Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
                ],
              ),
              currentIndex: 0,
              cache: cache,
              loader: (chapter) {
                requested.add(chapter.itemId);
                return pending.future;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 2 章'));
      await tester.pump();
      expect(requested, ['3']);
      expect(find.text('正在缓存 1 / 2 章'), findsOneWidget);
      await tester.tap(find.text('停止缓存'));
      await tester.pump();
      pending.complete('不应在停止后保存的正文');
      await tester.pumpAndSettle();
      expect(await cache.cachedChapterIds('book'), {'2'});
      expect(find.textContaining('已停止缓存'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _EvictingCache extends MemoryChapterCache {
  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
  }) async {
    await super.write(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
    );
    if (chapterId == '2') content[bookId]?.remove('3');
  }
}
