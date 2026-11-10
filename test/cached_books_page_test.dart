import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/cached_books_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/widgets/cache/cache_page_widgets.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

void main() {
  testWidgets('缓存页标题与设置入口使用同一名称', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: CachedBooksPage(
          cacheStore: _ManagedMemoryCache(),
          readerStore: MemoryReaderStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ArchiveFeaturePage), findsOneWidget);
    expect(find.text('小说离线缓存'), findsOneWidget);
    expect(find.text('暂无缓存章节'), findsOneWidget);
    expect(find.byType(ArchiveSection), findsOneWidget);
    expect(find.byType(SettingsSectionHeader), findsNothing);
  });

  testWidgets('深色 OLED 下缓存卡片使用页面主题的表面色', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final savedMode = themeModeNotifier.value;
    final savedOled = oledModeNotifier.value;
    themeModeNotifier.value = ThemeMode.dark;
    oledModeNotifier.value = true;
    addTearDown(() {
      themeModeNotifier.value = savedMode;
      oledModeNotifier.value = savedOled;
    });
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
        theme: AppTheme.createTheme(Brightness.dark),
        home: CachedBooksPage(
          cacheStore: cache,
          readerStore: MemoryReaderStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final panel = find.byType(ContentPanel).first;
    final surface = tester.widget<Material>(
      find.descendant(of: panel, matching: find.byType(Material)).first,
    );
    expect(surface.color, const HomePalette(true, oled: true).surface);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('墨水屏下删除图标用黑色而不是删除红', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final original = einkModeNotifier.value;
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = original);
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
        home: CachedBooksPage(
          cacheStore: cache,
          readerStore: MemoryReaderStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final icon = tester.widget<Icon>(find.byIcon(LucideIcons.trash).first);
    expect(icon.color, Colors.black);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除《离线测试书》缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无缓存章节'), findsOneWidget);
      expect(history.entry?['chapterId'], '1');
      expect(await cache.cachedChapterIds('cached'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('经典主题恢复缓存统计、AppBar 与设置卡列表', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = await _oneCachedBook();
    await pumpCacheBooksWithStyle(tester, cache, classic: true);

    expect(find.byType(ClassicFeaturePage), findsOneWidget);
    expect(find.byType(ArchiveFeaturePage), findsNothing);
    expect(find.byType(CacheSummaryCard), findsOneWidget);
    expect(find.text('已缓存 1 本 · 共 1 章'), findsOneWidget);
    expect(find.textContaining('占用空间：'), findsOneWidget);
    expect(find.byType(ArchiveSection), findsNothing);
    expect(find.byTooltip('清空全部缓存'), findsOneWidget);
    expect(find.byKey(const Key('cached_book_export_cached')), findsOneWidget);
    expect(find.byTooltip('删除《离线测试书》缓存'), findsOneWidget);
  });

  testWidgets('经典主题删除单本后回到经典空态', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = await _oneCachedBook();
    await pumpCacheBooksWithStyle(tester, cache, classic: true);

    await tester.tap(find.byTooltip('删除《离线测试书》缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(await cache.cachedChapterIds('cached'), isEmpty);
    expect(find.byType(CacheEmptyState), findsOneWidget);
    expect(find.textContaining('暂无缓存章节'), findsOneWidget);
    expect(find.byType(CacheSummaryCard), findsNothing);
  });

  testWidgets('切换主题保留缓存页 State 并回到档案壳', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = await _oneCachedBook();
    final store = await pumpCacheBooksWithStyle(tester, cache, classic: true);
    final state = tester.state(find.byType(CachedBooksPage));

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();

    expect(find.byType(ArchiveFeaturePage), findsOneWidget);
    expect(find.byType(ClassicFeaturePage), findsNothing);
    expect(tester.state(find.byType(CachedBooksPage)), same(state));
  });

  testWidgets('40 条缓存：切主题按同一本书和行内偏移恢复（中段与尾部）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cache = await _manyCachedBooks();
    final styleStore = AppThemeStyleStore()..value = AppThemeStyle.archive;
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

    final list = find.byKey(const ValueKey('cached-books-scroll'));
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(1300);
    await tester.pump();

    final mid = _firstVisibleBook(tester, list);
    expect(mid, isNotNull);
    await styleStore.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    expect(find.byType(ClassicFeaturePage), findsOneWidget);
    final midAfter = _firstVisibleBook(tester, list);
    expect(midAfter, isNotNull);
    expect(midAfter!.id, mid!.id);
    expect(midAfter.offset, closeTo(mid.offset, 1.0));

    // 尾部：第 31 本仍有足够行垫底，能保持同一行内偏移。
    final tailRow = find.byKey(const ValueKey('cached-book-row-book-30'));
    await tester.scrollUntilVisible(tailRow, 260, scrollable: scrollable);
    await tester.ensureVisible(tailRow);
    await tester.pump();
    final tail = _firstVisibleBook(tester, list);
    await styleStore.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();

    expect(find.byType(ArchiveFeaturePage), findsOneWidget);
    final tailAfter = _firstVisibleBook(tester, list);
    expect(tailAfter, isNotNull);
    expect(tailAfter!.id, tail!.id);
    expect(tailAfter.offset, closeTo(tail.offset, 1.0));
  });
}

Future<_ManagedMemoryCache> _oneCachedBook() async {
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
  return cache;
}

({String id, double offset})? _firstVisibleBook(
  WidgetTester tester,
  Finder list,
) {
  final viewport = tester.getRect(list);
  final contentTop = viewport.top + kToolbarHeight;
  for (var index = 0; index < 40; index++) {
    final finder = find.text('Book ${index + 1}');
    if (finder.evaluate().isEmpty) continue;
    final rect = tester.getRect(finder);
    if (rect.bottom <= contentTop + 0.5) continue;
    if (rect.top < contentTop - 0.5) continue;
    if (rect.bottom > viewport.bottom + 0.5) continue;
    return (id: 'book-$index', offset: contentTop - rect.top);
  }
  return null;
}

Future<_ManagedMemoryCache> _manyCachedBooks() async {
  final cache = _ManagedMemoryCache();
  for (var index = 0; index < 40; index++) {
    final id = 'book-$index';
    await cache.saveBook(
      CachedBook(
        id: id,
        title: 'Book ${index + 1}',
        chapters: [Chapter(itemId: '1', title: '缓存章节', volumeName: '')],
      ),
    );
    await cache.write(bookId: id, chapterId: '1', title: '缓存章节', text: '缓存正文');
  }
  return cache;
}

Future<AppThemeStyleStore> pumpCacheBooksWithStyle(
  WidgetTester tester,
  ChapterCacheStore cache, {
  required bool classic,
}) async {
  final store = AppThemeStyleStore()
    ..value = classic ? AppThemeStyle.classic : AppThemeStyle.archive;
  addTearDown(store.dispose);
  await tester.pumpWidget(
    AppUiHost(
      store: store,
      home: CachedBooksPage(
        cacheStore: cache,
        readerStore: MemoryReaderStore(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
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
