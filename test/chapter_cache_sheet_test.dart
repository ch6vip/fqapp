import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';

import 'support/fakes.dart';

void main() {
  for (final scenario
      in <
        ({int chapters, int start, bool cachedCurrent, List<String> fetched})
      >[
        (chapters: 1, start: 0, cachedCurrent: false, fetched: ['0']),
        (chapters: 3, start: 0, cachedCurrent: false, fetched: ['0', '1', '2']),
        (chapters: 4, start: 2, cachedCurrent: false, fetched: ['2', '3']),
        (chapters: 3, start: 0, cachedCurrent: true, fetched: ['1', '2']),
      ]) {
    testWidgets('U03 include current: ${scenario.chapters} chapters, '
        'start ${scenario.start}, cached ${scenario.cachedCurrent}', (
      tester,
    ) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      final cache = MemoryChapterCache();
      final currentText = ChapterContent.fromPlainText(
        '已缓存的当前章节',
        illustrationsChecked: true,
      ).toCacheText();
      if (scenario.cachedCurrent) {
        await cache.write(
          bookId: 'book',
          chapterId: '${scenario.start}',
          title: '当前章节',
          text: currentText,
        );
      }
      final fetched = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChapterCacheSheet(
              book: CachedBook(
                id: 'book',
                title: '下载范围测试',
                chapters: [
                  for (var i = 0; i < scenario.chapters; i++)
                    Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
                ],
              ),
              currentIndex: scenario.start,
              includeCurrentChapter: true,
              cache: cache,
              loader: (chapter) async {
                fetched.add(chapter.itemId);
                return ChapterContent.fromPlainText(
                  '下载的正文${chapter.itemId}',
                  illustrationsChecked: true,
                ).toCacheText();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存 ${scenario.chapters - scenario.start} 章'));
      await tester.pumpAndSettle();
      expect(fetched, scenario.fetched);
      expect(await cache.cachedChapterIds('book'), {
        for (var i = scenario.start; i < scenario.chapters; i++) '$i',
      });
      if (scenario.cachedCurrent) {
        expect(cache.content['book']!['${scenario.start}'], currentText);
      }
      expect(cache.catalogs['book']!.chapters, hasLength(scenario.chapters));
      expect(find.textContaining('缓存完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('U03 reader default keeps its cached current chapter', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final cache = MemoryChapterCache();
    final current = ChapterContent.fromPlainText(
      '读者正在阅读的正文',
      illustrationsChecked: true,
    ).toCacheText();
    await cache.write(
      bookId: 'book',
      chapterId: '0',
      title: '第0章',
      text: current,
    );
    final fetched = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChapterCacheSheet(
            book: CachedBook(
              id: 'book',
              title: '阅读中缓存',
              chapters: [
                for (var i = 0; i < 3; i++)
                  Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
              ],
            ),
            currentIndex: 0,
            cache: cache,
            loader: (chapter) async {
              fetched.add(chapter.itemId);
              return '后续章节${chapter.itemId}';
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存后 2 章'));
    await tester.pumpAndSettle();
    expect(fetched, ['1', '2']);
    expect(cache.content['book']!['0'], current);
    expect(await cache.cachedChapterIds('book'), {'0', '1', '2'});
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('detail download caches the whole remainder in one action', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final cache = MemoryChapterCache();
    final fetched = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChapterCacheSheet(
            book: CachedBook(
              id: 'book',
              title: '全部下载测试',
              chapters: [
                for (var i = 0; i < 101; i++)
                  Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
              ],
            ),
            currentIndex: 0,
            includeCurrentChapter: true,
            cache: cache,
            loader: (chapter) async {
              fetched.add(chapter.itemId);
              return ChapterContent.fromPlainText(
                '正文${chapter.itemId}',
                illustrationsChecked: true,
              ).toCacheText();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部下载 101 章'));
    await tester.pumpAndSettle();
    expect(fetched, hasLength(101));
    expect(await cache.cachedChapterIds('book'), hasLength(101));
    expect(cache.pinned['book'], hasLength(101));
    expect(find.textContaining('缓存完成'), findsOneWidget);
    expect(find.textContaining('缓存上限'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('whole-book download runs past the cache capacity', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final cache = MemoryChapterCache(chapterCapacity: 3);
    final fetched = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChapterCacheSheet(
            book: CachedBook(
              id: 'book',
              title: '超长目录',
              chapters: [
                for (var i = 0; i < 101; i++)
                  Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
              ],
            ),
            currentIndex: 0,
            includeCurrentChapter: true,
            cache: cache,
            loader: (chapter) async {
              fetched.add(chapter.itemId);
              return ChapterContent.fromPlainText(
                '正文${chapter.itemId}',
                illustrationsChecked: true,
              ).toCacheText();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The store's automatic budget cannot truncate a download the user asked
    // for, and every chapter of the batch is pinned.
    await tester.tap(find.text('全部下载 101 章'));
    await tester.pumpAndSettle();
    expect(fetched, hasLength(101));
    expect(await cache.cachedChapterIds('book'), hasLength(101));
    expect(cache.pinned['book'], hasLength(101));
    expect(find.textContaining('缓存完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short remainder keeps the preset buttons', (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChapterCacheSheet(
            book: CachedBook(
              id: 'book',
              title: '短目录',
              chapters: [
                for (var i = 0; i < 3; i++)
                  Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
              ],
            ),
            currentIndex: 0,
            includeCurrentChapter: true,
            cache: MemoryChapterCache(),
            loader: (chapter) async => '正文${chapter.itemId}',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('缓存 3 章'), findsOneWidget);
    expect(find.byKey(const Key('chapter_cache_all')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reader whole-book batch pins every following chapter', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final cache = MemoryChapterCache(chapterCapacity: 4);
    final fetched = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChapterCacheSheet(
            book: CachedBook(
              id: 'book',
              title: '阅读器里下载',
              chapters: [
                for (var i = 0; i < 102; i++)
                  Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
              ],
            ),
            currentIndex: 0,
            cache: cache,
            loader: (chapter) async {
              fetched.add(chapter.itemId);
              return ChapterContent.fromPlainText(
                '正文${chapter.itemId}',
                illustrationsChecked: true,
              ).toCacheText();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The reader starts after the current chapter, and the batch is pinned: the
    // capacity of 4 does not cut it to four chapters.
    await tester.tap(find.text('全部下载 101 章'));
    await tester.pumpAndSettle();
    expect(fetched, [for (var i = 1; i <= 101; i++) '$i']);
    expect(cache.pinned['book'], hasLength(101));
    expect(find.textContaining('缓存完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preset batches stay inside the automatic budget', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final cache = MemoryChapterCache();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChapterCacheSheet(
            book: CachedBook(
              id: 'book',
              title: '短目录',
              chapters: [
                for (var i = 0; i < 3; i++)
                  Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
              ],
            ),
            currentIndex: 0,
            includeCurrentChapter: true,
            cache: cache,
            loader: (chapter) async => '正文${chapter.itemId}',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存 3 章'));
    await tester.pumpAndSettle();
    // Only the whole-book action is a user download; a preset batch is still
    // ordinary cache the LRU pass may reclaim.
    expect(await cache.cachedChapterIds('book'), hasLength(3));
    expect(cache.pinned['book'], isNull);
    expect(tester.takeException(), isNull);
  });
}

class _EvictingCache extends MemoryChapterCache {
  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async {
    await super.write(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      pinned: pinned,
    );
    if (chapterId == '2') content[bookId]?.remove('3');
  }
}
