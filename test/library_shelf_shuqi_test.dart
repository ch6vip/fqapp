import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/pages/shuqi_detail_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/shelf_view_store.dart';
import 'package:fqapp/widgets/shelf/book_collection_tiles.dart';

import 'support/fakes.dart';

/// 书旗与番茄同数字 id 并存：身份、打开路径、历史 / 缓存 / 更新检测互不串。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    setSingleChapterPrefs({'shelfLayout': 'list'});
    ShelfViewStore.instance.resetForTest();
    directory = await Directory.systemTemp.createTemp('fqapp-shelf-shuqi-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temp directory cleanup is noise.
    }
  });

  testWidgets('同数字 id 的番茄与书旗条目并存', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('123', title: '番茄书'));
      await ShelfStore.instance.add(
        _item('123', title: '书旗书', source: 'shuqi'),
      );
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shelf-book-book:123')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shelf-book-shuqi/book:123')),
      findsOneWidget,
    );
    expect(find.text('番茄书'), findsWidgets);
    expect(find.text('书旗书'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('书旗条目打开自己的详情页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(
        _item('123', title: '书旗书', source: 'shuqi'),
      );
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shelf-book-shuqi/book:123')));
    for (
      var attempt = 0;
      attempt < 30 &&
          find.byType(ShuqiDetailPage, skipOffstage: false).evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.byType(ShuqiDetailPage, skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('番茄历史进度不会串到同 id 书旗条目', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('123', title: '番茄书'));
      await ShelfStore.instance.add(
        _item('123', title: '书旗书', source: 'shuqi'),
      );
      await LibraryStore.instance.addHistory({
        'id': '123',
        'kind': 'book',
        'title': '番茄书',
        'episode': 4,
        'chapterCount': 10,
        'progress': 0.5,
        'time': DateTime.now().millisecondsSinceEpoch,
      });
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final fanqie = tester.widget<ShelfNovelRow>(
      find.byKey(const ValueKey('shelf-book-book:123')),
    );
    final shuqi = tester.widget<ShelfNovelRow>(
      find.byKey(const ValueKey('shelf-book-shuqi/book:123')),
    );
    expect(fanqie.progress, '第5章 · 共10章');
    expect(shuqi.progress, isNull);
    expect(find.text('第5章 · 共10章'), findsOneWidget);
  });

  testWidgets('更新检测只处理番茄书，书旗条目不会出现更新角标', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('123', title: '番茄书'));
      await ShelfStore.instance.add(
        _item('123', title: '书旗书', source: 'shuqi'),
      );
      await LibraryStore.instance.addHistory({
        'id': '123',
        'kind': 'book',
        'title': '番茄书',
        'episode': 1,
        'chapterCount': 2,
        'progress': 1.0,
      });
    });
    final cache = MemoryChapterCache();
    await cache.saveBook(
      CachedBook(
        id: '123',
        title: '番茄书',
        chapters: [
          Chapter(itemId: '1', title: '第一章', volumeName: ''),
          Chapter(itemId: '2', title: '第二章', volumeName: ''),
          Chapter(itemId: '3', title: '第三章', volumeName: ''),
        ],
      ),
    );
    await tester.pumpWidget(_app(cache: cache));
    await tester.pumpAndSettle();

    expect(find.text('更新'), findsOneWidget);
    final fanqie = tester.widget<ShelfNovelRow>(
      find.byKey(const ValueKey('shelf-book-book:123')),
    );
    final shuqi = tester.widget<ShelfNovelRow>(
      find.byKey(const ValueKey('shelf-book-shuqi/book:123')),
    );
    expect(fanqie.badge, '更新');
    expect(shuqi.badge, isNull);
  });

  testWidgets('已缓存来源筛选只命中番茄书', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('123', title: '番茄书'));
      await ShelfStore.instance.add(
        _item('123', title: '书旗书', source: 'shuqi'),
      );
    });
    final cache = _SummaryCache([
      CachedBookSummary(
        CachedBook(
          id: '123',
          title: '番茄书',
          chapters: [Chapter(itemId: '1', title: '第一章', volumeName: '')],
        ),
        const ChapterCacheStats(chapterCount: 1, byteCount: 100),
      ),
    ]);
    await tester.pumpWidget(_app(cache: cache));
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(
      tester
          .widget<ShelfNovelRow>(
            find.byKey(const ValueKey('shelf-book-book:123')),
          )
          .cached,
      isTrue,
      reason: '缓存扫描应已完成',
    );

    await tester.tap(find.byKey(const Key('shelf-filter')));
    await tester.pumpAndSettle();
    final cached = find.byKey(const ValueKey('shelf-filter-source-cached'));
    await tester.ensureVisible(cached);
    await tester.pumpAndSettle();
    await tester.tap(cached);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shelf-book-book:123')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shelf-book-shuqi/book:123')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _app({ChapterCache? cache}) =>
    MaterialApp(home: LibraryPage(cacheStore: cache));

/// A `ChapterCacheStore` whose catalogue summary is already in memory, so the
/// page's scan completes inside the widget test's fake-async zone.
class _SummaryCache extends ChapterCacheStore {
  _SummaryCache(this.summaries);

  final List<CachedBookSummary> summaries;

  @override
  Future<List<CachedBookSummary>> books() async => summaries;
}

MediaItem _item(
  String id, {
  String? title,
  String kind = 'book',
  String source = 'fanqie',
}) => MediaItem(
  id: id,
  title: title ?? id,
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '120',
  kind: kind,
  source: source,
);
