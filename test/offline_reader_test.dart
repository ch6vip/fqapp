import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/cached_book_reader.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';

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
}

class _UnreadableChapterCache extends MemoryChapterCache {
  @override
  Future<CachedBook?> cachedBook(String bookId) async =>
      throw StateError('cache unavailable');
}
