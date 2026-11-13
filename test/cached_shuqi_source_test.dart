import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/shuqi_book.dart';
import 'package:fqapp/pages/cached_book_reader.dart';
import 'package:fqapp/pages/cached_books_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/book_txt_export.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/shuqi_reader_source.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

final _first = Chapter(itemId: '10', title: '第一章', volumeName: '');
final _second = Chapter(itemId: '20', title: '第二章', volumeName: '');
final _book = CachedBook(
  id: 'shuqi:34078',
  title: '书旗缓存书',
  chapters: [_first, _second],
);
final _item = MediaItem(
  id: '34078',
  title: '书旗书架标题',
  cover: '',
  author: '书旗作者',
  badge: '',
  ep: '',
  kind: 'book',
  source: shuqiSourceId,
);

Map<String, dynamic> _toc() => {
  'data': {
    'path': 'h5',
    'chapters': [
      {'chapterId': '10', 'title': '第一章'},
      {'chapterId': '20', 'title': '第二章'},
    ],
  },
};

Future<_CacheStore> _cache() async {
  final cache = _CacheStore();
  await cache.saveBook(_book);
  await cache.write(
    bookId: _book.id,
    chapterId: _first.itemId,
    title: _first.title,
    text: ChapterContent.fromPlainText('第一章\n书旗缓存正文').toCacheText(),
  );
  return cache;
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'reader_scroll_chapter_mode': 'replace',
    }),
  );

  test('Shuqi cache identity accepts only a nonempty numeric book ID', () {
    expect(shuqiBookIdFromReaderId('shuqi:34078'), '34078');
    expect(shuqiBookIdFromReaderId('34078'), isNull);
    expect(shuqiBookIdFromReaderId('shuqi:'), isNull);
    expect(shuqiBookIdFromReaderId('shuqi:abc'), isNull);
    expect(shuqiBookIdFromReaderId('shuqi:34078:10'), isNull);
  });

  testWidgets(
    'malformed Shuqi cache IDs cannot open or export through Fanqie',
    (tester) async {
      final cache = _CacheStore();
      final invalid = CachedBook(
        id: 'shuqi:abc',
        title: '无效缓存',
        chapters: [_first],
      );
      await cache.saveBook(invalid);
      await cache.write(
        bookId: invalid.id,
        chapterId: '10',
        title: '第一章',
        text: '缓存正文',
      );
      final sink = _Sink();
      var fanqieCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CachedBooksPage(
            cacheStore: cache,
            exportSink: sink,
            exportDirectoryLoader: (_) async {
              fanqieCalls++;
              return [_first];
            },
            exportChapterLoader: (_) async {
              fanqieCalls++;
              return '不应请求';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cached_book_export_shuqi:abc')));
      await tester.pumpAndSettle();
      expect(find.textContaining('书旗缓存标识无效'), findsOneWidget);
      expect(fanqieCalls, 0);
      expect(sink.texts, isEmpty);
      final context = tester.element(find.byType(CachedBooksPage));
      await expectLater(
        openCachedBook(context, book: invalid, cache: cache.memory),
        throwsStateError,
      );
      expect(find.byType(ReaderPage), findsNothing);
    },
  );

  test('offline shelf lookup separates numeric IDs by source', () async {
    final cache = await _cache();
    await cache.saveBook(
      CachedBook(id: '34078', title: '同号番茄书', chapters: [_second]),
    );
    await cache.write(
      bookId: '34078',
      chapterId: '20',
      title: '番茄章',
      text: '番茄正文',
    );

    final shuqi = await cachedBookForOfflineOpen(
      _item,
      cache: cache.memory,
      connectivity: (online: false, metered: false),
    );
    expect(shuqi!.id, 'shuqi:34078');
    expect(shuqi.title, _item.title);
    expect(shuqi.chapters.first.itemId, '10');
    final fanqie = await cachedBookForOfflineOpen(
      _item.copyWith(source: 'fanqie'),
      cache: cache.memory,
      connectivity: (online: false, metered: false),
    );
    expect(fanqie!.id, '34078');
    expect(fanqie.chapters.single.itemId, '20');
    expect(
      await cachedBookForOfflineOpen(
        _item,
        cache: cache.memory,
        connectivity: (online: true, metered: false),
      ),
      isNull,
    );
  });

  testWidgets(
    'cached opening restores raw Shuqi shelf identity and drops history',
    (tester) async {
      final cache = await _cache();
      final history = _CountingHistory()
        ..entry = {'id': '34078', 'kind': 'book', 'chapterId': '20'};
      bool? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                opened = await openCachedBook(
                  context,
                  book: _book,
                  cache: cache.memory,
                  readerStore: history,
                );
              },
              child: const Text('打开缓存'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开缓存'));
      await tester.pumpAndSettle();
      final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
      expect(reader.bookId, 'shuqi:34078');
      expect(reader.startIndex, 0);
      expect(reader.localOnly, isTrue);
      expect(reader.chapterCache, same(cache.memory));
      expect(reader.shelfItem!.id, '34078');
      expect(reader.shelfItem!.source, shuqiSourceId);
      expect(reader.shelfItem!.kind, 'book');
      expect(reader.readerStore, isA<ReadOnlyReaderStore>());
      expect(history.reads, 0);
      expect(history.entry!['id'], '34078');
      expect(history.seconds, 0);
      // This offline entry never falls back to Fanqie on a missing chapter.
      await expectLater(
        reader.chapterLoader!(_second),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('书旗章节未缓存'),
          ),
        ),
      );
      await reader.readerStore!.addHistory({'id': _book.id, 'kind': 'book'});
      await reader.readerStore!.updateProgress(_book.id, 1, 0.5);
      await reader.readerStore!.accumulateReadTime(_book.id, 'book', 60);
      expect(await reader.readerStore!.historyEntry(_book.id), isNull);
      expect(history.entry!['chapterId'], '20');
      Navigator.of(tester.element(find.byType(ReaderPage))).pop();
      await tester.pumpAndSettle();
      expect(opened, isTrue);
    },
  );

  testWidgets('recent Shuqi opening never reads a same-ID Fanqie history', (
    tester,
  ) async {
    final history = _CountingHistory()
      ..entry = {'id': '34078', 'kind': 'book', 'chapterId': '10'};
    final cache = await _cache();
    var directoryCalls = 0;
    bool? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              opened = await openRecentBook(
                context,
                _item,
                cache: cache.memory,
                readerStore: history,
                directoryLoader: (_) async {
                  directoryCalls++;
                  return [_first];
                },
              );
            },
            child: const Text('最近阅读'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('最近阅读'));
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(history.reads, 0);
    expect(directoryCalls, 0);
    expect(find.byType(ReaderPage), findsNothing);
  });

  for (final style in AppThemeStyle.values) {
    testWidgets(
      '${style.name} cache management labels source and deletes only Shuqi',
      (tester) async {
        final cache = await _cache();
        await cache.saveBook(
          CachedBook(id: '34078', title: '同号番茄书', chapters: [_first]),
        );
        await cache.write(
          bookId: '34078',
          chapterId: '10',
          title: '番茄章',
          text: '番茄正文',
        );
        final styleStore = AppThemeStyleStore()..value = style;
        addTearDown(styleStore.dispose);
        await tester.pumpWidget(
          AppUiHost(
            store: styleStore,
            home: CachedBooksPage(
              cacheStore: cache,
              readerStore: MemoryReaderStore(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('书旗 · 1/2 章'), findsOneWidget);
        expect(find.textContaining('番茄 · 1/1 章'), findsOneWidget);
        expect(find.textContaining('已缓存 2 本 · 共 2 章'), findsOneWidget);
        await tester.tap(find.byTooltip('删除《书旗缓存书》缓存'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除').last);
        await tester.pumpAndSettle();
        expect(cache.clearedIds, ['shuqi:34078']);
        expect(cache.memory.content['34078']!['10'], '番茄正文');
        expect(find.text('书旗缓存书'), findsNothing);
        expect(find.text('同号番茄书'), findsOneWidget);
        expect(find.textContaining('已缓存 1 本 · 共 1 章'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'Shuqi whole-book export reuses cache and fetches fresh chapters only from Shuqi',
    (tester) async {
      final cache = await _cache();
      final sink = _Sink();
      final requests = <String>[];
      var fanqieCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CachedBooksPage(
            cacheStore: cache,
            exportSink: sink,
            exportDirectoryLoader: (_) async {
              fanqieCalls++;
              throw StateError('wrong source');
            },
            exportChapterLoader: (_) async {
              fanqieCalls++;
              throw StateError('wrong source');
            },
            exportShuqiTocLoader: (id) async {
              requests.add('toc:$id');
              return _toc();
            },
            exportShuqiChapterLoader: (id, chapterId) async {
              requests.add('chapter:$id:$chapterId');
              return {
                'data': {'content': '书旗新章正文'},
              };
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cached_book_export_shuqi:34078')));
      await tester.pumpAndSettle();
      expect(fanqieCalls, 0);
      expect(requests, ['toc:34078', 'chapter:34078:20']);
      expect(sink.texts, ['# 第一章\n书旗缓存正文\n\n# 第二章\n书旗新章正文\n\n']);
      expect(await cache.cachedChapterIds(_book.id), {'10'});
      expect(find.textContaining('已导出《书旗缓存书》2 章'), findsOneWidget);
    },
  );

  testWidgets(
    'Shuqi cancellation during a cache read never starts a later network fetch',
    (tester) async {
      final cache = await _cache();
      final gate = Completer<String?>();
      cache.pendingRead = gate.future;
      final sink = _Sink();
      var chapterCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CachedBooksPage(
            cacheStore: cache,
            exportSink: sink,
            exportShuqiTocLoader: (_) async => _toc(),
            exportShuqiChapterLoader: (_, _) async {
              chapterCalls++;
              return {
                'data': {'content': '不应请求'},
              };
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('cached_book_export_shuqi:34078'));
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byTooltip('取消导出'), findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      gate.complete(null);
      await tester.pumpAndSettle();
      expect(chapterCalls, 0);
      expect(sink.texts, isEmpty);
      expect(find.textContaining('已取消导出'), findsOneWidget);
      expect(await cache.cachedChapterIds(_book.id), {'10'});
    },
  );

  testWidgets(
    'Shuqi directory failure does not fall back to a cached-only or Fanqie export',
    (tester) async {
      final cache = await _cache();
      final sink = _Sink();
      var fanqieCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CachedBooksPage(
            cacheStore: cache,
            exportSink: sink,
            exportDirectoryLoader: (_) async {
              fanqieCalls++;
              return [_first];
            },
            exportShuqiTocLoader: (_) async => throw StateError('offline'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cached_book_export_shuqi:34078')));
      await tester.pumpAndSettle();
      expect(fanqieCalls, 0);
      expect(sink.texts, isEmpty);
      expect(find.textContaining('目录获取失败'), findsOneWidget);
    },
  );
}

class _CountingHistory extends MemoryReaderStore {
  int reads = 0;

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) {
    reads++;
    return super.historyEntry(id);
  }
}

class _Sink implements TxtSink {
  final texts = <String>[];

  @override
  Future<ExportTarget> saveText({
    required String fileName,
    required String text,
  }) async {
    texts.add(text);
    return ExportTarget(path: '/Download/$fileName', isPublic: true);
  }
}

class _CacheStore extends ChapterCacheStore {
  final memory = MemoryChapterCache();
  final clearedIds = <String?>[];
  Future<String?>? pendingRead;

  @override
  Future<String?> read({required String bookId, required String chapterId}) =>
      pendingRead ?? memory.read(bookId: bookId, chapterId: chapterId);

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) => memory.write(
    bookId: bookId,
    chapterId: chapterId,
    title: title,
    text: text,
    pinned: pinned,
  );

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
    clearedIds.add(bookId);
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
