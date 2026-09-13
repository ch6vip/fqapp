import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'text fallback remains readable on a cold cache without claiming images are complete',
    (tester) async {
      final cache = MemoryChapterCache();
      final fallback = ChapterContent.fromPlainText('可离线阅读的正文');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChapterCacheSheet(
              book: CachedBook(
                id: 'book',
                title: '缓存测试',
                chapters: [
                  Chapter(itemId: '1', title: '第一章', volumeName: ''),
                  Chapter(itemId: '2', title: '第二章', volumeName: ''),
                ],
              ),
              currentIndex: 0,
              cache: cache,
              loader: (_) async => fallback.toCacheText(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 1 章'));
      await tester.pumpAndSettle();
      expect(cache.content['book']!['2'], fallback.toCacheText());
      expect(find.textContaining('插图未更新'), findsOneWidget);
      expect(find.textContaining('缓存完成'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'text fallback preserves cached pictures and reports incomplete images',
    (tester) async {
      final cache = MemoryChapterCache();
      final old = ChapterContent(
        blocks: const [
          ChapterParagraph('已有的正文'),
          ChapterImage(
            url: 'https://images.test/old?x-expires=1',
            width: 100,
            height: 200,
          ),
        ],
      );
      await cache.write(
        bookId: 'book',
        chapterId: '2',
        title: '第二章',
        text: old.toCacheText(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChapterCacheSheet(
              book: CachedBook(
                id: 'book',
                title: '缓存测试',
                chapters: [
                  Chapter(itemId: '1', title: '第一章', volumeName: ''),
                  Chapter(itemId: '2', title: '第二章', volumeName: ''),
                ],
              ),
              currentIndex: 0,
              cache: cache,
              loader: (_) async =>
                  ChapterContent.fromPlainText('已有的正文').toCacheText(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 1 章'));
      await tester.pumpAndSettle();
      expect(cache.content['book']!['2'], old.toCacheText());
      expect(find.textContaining('插图未更新'), findsOneWidget);
      expect(find.textContaining('缓存完成'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
    expect(find.textContaining('插图未更新'), findsOneWidget);
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
      expect(find.textContaining('插图未更新'), findsOneWidget);
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
        text: ChapterContent.fromPlainText(
          '已缓存',
          illustrationsChecked: true,
        ).toCacheText(),
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
