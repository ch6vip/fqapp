import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/cached_book_reader.dart';
import 'package:fqapp/pages/comic_reader_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/media_history_store.dart';

import 'support/fakes.dart';

/// 离线直读：官方从书架/下载列表点书直接进阅读器，这条路径必须不碰网络。
void main() {
  group('openRecentBook', () {
    final item = MediaItem(
      id: 'recent',
      title: '最近阅读',
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );
    for (final scenario in <String, Map<String, dynamic>?>{
      '没有阅读记录': null,
      '记录属于听书': {'kind': 'audio', 'chapterId': '1'},
      '原章节正文已清除': {'chapterId': '2', 'episode': 0},
      '目录不含原章节': {'chapterId': 'gone', 'episode': 0, 'fanqieImported': true},
      '旧下标无效': {'episode': -1},
      '缓存不可读': {'chapterId': '1'},
    }.entries) {
      testWidgets('${scenario.key}时回退，不替换为其他缓存章节', (tester) async {
        SharedPreferences.setMockInitialValues({});
        final cache = scenario.key == '缓存不可读'
            ? _UnreadableChapterCache()
            : MemoryChapterCache();
        await cache.saveBook(
          CachedBook(
            id: 'recent',
            title: '最近阅读',
            chapters: [
              Chapter(itemId: '1', title: '第一章', volumeName: ''),
              Chapter(itemId: '2', title: '第二章', volumeName: ''),
            ],
          ),
        );
        await cache.write(
          bookId: 'recent',
          chapterId: '1',
          title: '第一章',
          text: '缓存正文',
        );
        bool? opened;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  opened = await openRecentBook(
                    context,
                    item,
                    cache: cache,
                    readerStore: MemoryReaderStore(entry: scenario.value),
                  );
                },
                child: const Text('续读'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('续读'));
        await tester.pumpAndSettle();
        expect(opened, isFalse);
        expect(find.byType(ReaderPage, skipOffstage: false), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('cachedStartIndex', () {
    final book = CachedBook(
      id: 'b',
      title: '书',
      chapters: [
        Chapter(itemId: '1', title: '第一章', volumeName: ''),
        Chapter(itemId: '2', title: '第二章', volumeName: ''),
        Chapter(itemId: '3', title: '第三章', volumeName: ''),
      ],
    );

    test('认上次读到的章节，哪怕它排在后面', () {
      expect(cachedStartIndex(book, {'2'}, {'chapterId': '2'}), 1);
    });

    test('章节 id 对不上时退回阅读进度', () {
      expect(cachedStartIndex(book, {'3'}, {'episode': 2}), 2);
    });

    test('进度坏掉时不抛异常，退到第一个有缓存的章节', () {
      expect(cachedStartIndex(book, {'3'}, {'episode': 'invalid'}), 2);
      expect(cachedStartIndex(book, {'3'}, {'episode': double.nan}), 2);
    });

    test('没有历史时退到第一个有缓存的章节', () {
      expect(cachedStartIndex(book, {'2'}, null), 1);
    });

    test('缓存章节一个都不在目录里时返回 -1', () {
      expect(cachedStartIndex(book, {'gone'}, null), -1);
    });

    test('空目录返回 -1 而不是崩在 clamp 上', () {
      expect(
        cachedStartIndex(CachedBook(id: 'b', title: '书', chapters: const []), {
          '1',
        }, null),
        -1,
      );
    });
  });

  group('cachedBookForOfflineOpen', () {
    final item = MediaItem(
      id: 'book',
      title: '书架上的书名',
      cover: 'cover-url',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );

    Future<MemoryChapterCache> cacheWith(String bookId) async {
      final cache = MemoryChapterCache();
      await cache.write(
        bookId: bookId,
        chapterId: '1',
        title: '第一章',
        text: '离线正文',
      );
      return cache;
    }

    MediaItem itemOf(String kind, {String id = 'book'}) => MediaItem(
      id: id,
      title: '书架上的书名',
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: kind,
    );

    test('无网 + 小说 + 有缓存：给出可直读的书，标题取书架上的', () async {
      final book = await cachedBookForOfflineOpen(
        item,
        cache: await cacheWith('book'),
        connectivity: (online: false, metered: false),
      );
      expect(book, isNotNull);
      expect(book!.id, 'book');
      expect(book.title, '书架上的书名');
      expect(book.cover, 'cover-url');
      expect(book.chapters, hasLength(1));
    });

    test('在线时不抢在详情页前面', () async {
      expect(
        await cachedBookForOfflineOpen(
          item,
          cache: await cacheWith('book'),
          connectivity: (online: true, metered: false),
        ),
        isNull,
      );
    });

    test('没有缓存章节时交给详情页', () async {
      expect(
        await cachedBookForOfflineOpen(
          item,
          cache: MemoryChapterCache(),
          connectivity: (online: false, metered: false),
        ),
        isNull,
      );
    });

    test('非小说类型不走这条路', () async {
      expect(
        await cachedBookForOfflineOpen(
          itemOf('video'),
          cache: await cacheWith('book'),
          connectivity: (online: false, metered: false),
        ),
        isNull,
      );
    });

    test('id 为空时不动', () async {
      expect(
        await cachedBookForOfflineOpen(
          itemOf('book', id: ''),
          cache: await cacheWith('book'),
          connectivity: (online: false, metered: false),
        ),
        isNull,
      );
    });
  });

  testWidgets('有缓存章节时直接进阅读器', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = MemoryChapterCache();
    await cache.saveBook(
      CachedBook(
        id: 'book',
        title: '离线书',
        chapters: [Chapter(itemId: '1', title: '第一章', volumeName: '')],
      ),
    );
    await cache.write(
      bookId: 'book',
      chapterId: '1',
      title: '第一章',
      text: '离线正文',
    );

    bool? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              opened = await openCachedBook(
                context,
                book: cache.catalogs['book']!,
                cache: cache,
                readerStore: MemoryReaderStore(),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage, skipOffstage: false), findsOneWidget);
    // openCachedBook 等的是这次导航的生命周期：阅读器关掉它才返回 true。
    Navigator.of(tester.element(find.byType(ReaderPage))).pop();
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('没有缓存章节时不进阅读器，把回退留给调用方', (tester) async {
    SharedPreferences.setMockInitialValues({});
    bool? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              opened = await openCachedBook(
                context,
                book: CachedBook(
                  id: 'empty',
                  title: '没缓存的书',
                  chapters: [
                    Chapter(itemId: '1', title: '第一章', volumeName: ''),
                  ],
                ),
                cache: MemoryChapterCache(),
                readerStore: MemoryReaderStore(),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(find.byType(ReaderPage, skipOffstage: false), findsNothing);
  });

  group('openRecentBook 漫画', () {
    MediaItem mangaItem() => MediaItem(
      id: 'comic',
      title: '漫画',
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'manga',
    );

    Future<void> pumpTrigger(
      WidgetTester tester, {
      required ChapterCache cache,
      required ReaderStore store,
      required void Function(bool) onResult,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                onResult(
                  await openRecentBook(
                    context,
                    mangaItem(),
                    cache: cache,
                    readerStore: store,
                  ),
                );
              },
              child: const Text('续读'),
            ),
          ),
        ),
      );
    }

    testWidgets('目录缓存命中时直接进漫画阅读器，不进文字阅读器', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = MemoryChapterCache();
      await cache.saveBook(
        CachedBook(
          id: 'comic',
          title: '缓存漫画',
          chapters: [
            Chapter(itemId: '1', title: '第1话', volumeName: ''),
            Chapter(itemId: '2', title: '第2话', volumeName: ''),
          ],
        ),
      );
      // 漫画进度写在 'manga' 作用域里，这里用同一作用域写入才有意义。
      final store = scopedHistoryStore(MemoryReaderStore(), 'manga');
      await store.addHistory({
        'id': 'comic',
        'kind': 'manga',
        'chapterId': '2',
        'episode': 0,
      });

      await pumpTrigger(
        tester,
        cache: cache,
        store: store,
        onResult: (_) {},
      );
      await tester.tap(find.text('续读'));
      // 阅读器会去取图片：测试环境没有后端，落进错误态而不是抛异常，因此用
      // pump 而不是 pumpAndSettle（加载圈会让后者超时）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(ComicReaderPage), findsOneWidget);
      expect(find.byType(ReaderPage, skipOffstage: false), findsNothing);
      final page = tester.widget<ComicReaderPage>(find.byType(ComicReaderPage));
      expect(page.startIndex, 1);
      expect(page.title, '漫画');
      // 漫画不要求正文缓存，但目录必须来自缓存。
      expect(page.chapters.map((c) => c.itemId), ['1', '2']);
      // openRecentBook 要等阅读器关闭才返回，这里只验路由已经打开。
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('没有目录缓存时回退，不打开任何阅读器', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = scopedHistoryStore(MemoryReaderStore(), 'manga');
      await store.addHistory({
        'id': 'comic',
        'kind': 'manga',
        'chapterId': '1',
        'episode': 0,
      });

      bool? opened;
      await pumpTrigger(
        tester,
        cache: MemoryChapterCache(),
        store: store,
        onResult: (value) => opened = value,
      );
      await tester.tap(find.text('续读'));
      await tester.pumpAndSettle();

      expect(opened, isFalse);
      expect(find.byType(ComicReaderPage, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('漫画历史用未分作用域的 store 读不到，按未读过回退', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = MemoryChapterCache();
      await cache.saveBook(
        CachedBook(
          id: 'comic',
          title: '缓存漫画',
          chapters: [Chapter(itemId: '1', title: '第1话', volumeName: '')],
        ),
      );
      // 故意写进默认作用域：openRecentBook 必须去 'manga' 作用域找，
      // 找不到就回退，而不是误用小说的进度。
      final plain = MemoryReaderStore(
        entry: {'id': 'comic', 'kind': 'book', 'chapterId': '1'},
      );

      bool? opened;
      await pumpTrigger(
        tester,
        cache: cache,
        store: plain,
        onResult: (value) => opened = value,
      );
      await tester.tap(find.text('续读'));
      await tester.pumpAndSettle();

      expect(opened, isFalse);
      expect(find.byType(ComicReaderPage, skipOffstage: false), findsNothing);
    });

    testWidgets('漫画阅读器打开时把目录写进缓存', (tester) async {
      final cache = MemoryChapterCache();
      final chapters = [
        Chapter(itemId: '1', title: '第1话', volumeName: ''),
        Chapter(itemId: '2', title: '第2话', volumeName: ''),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderPage(
            bookId: 'comic',
            title: '漫画',
            chapters: chapters,
            startIndex: 0,
            readerStore: MemoryReaderStore(),
            cache: cache,
            chapterLoader: (_) async => const [],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 漫画只写目录，不写正文，所以必须从 savedCatalogue 读回来
      // （cachedBook 按「有可离线正文」回答，对漫画恒为 null）。
      expect(await cache.cachedBook('comic'), isNull);
      final book = await cache.savedCatalogue('comic');
      expect(book, isNotNull);
      expect(book!.chapters.map((c) => c.itemId), ['1', '2']);
      expect(book.title, '漫画');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

class _UnreadableChapterCache extends MemoryChapterCache {
  @override
  Future<CachedBook?> cachedBook(String bookId) async =>
      throw StateError('cache unavailable');
}
