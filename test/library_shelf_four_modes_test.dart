import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/shelf_view_store.dart';
import 'package:fqapp/widgets/wenku/archive_shelf.dart';

import 'support/fakes.dart';

/// 书架四模式、排序、阅读状态、来源与分类筛选的页面回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    setSingleChapterPrefs({'shelfLayout': 'list'});
    ShelfViewStore.instance.resetForTest();
    directory = await Directory.systemTemp.createTemp('fqapp-shelf-modes-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
  });

  tearDown(() async {
    await ShelfGroupStore.instance.whenIdle();
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

  testWidgets('四种版式渲染对应容器与立体书架头部', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('a', title: '甲书'));
      await ShelfStore.instance.add(_item('b', title: '乙书'));
    });

    for (final (mode, storage) in const [
      ('list', 'list'),
      ('shelf', 'shelf'),
      ('shelfGrid', 'shelfGrid'),
      ('grid', 'grid'),
    ]) {
      setSingleChapterPrefs({'shelfLayout': mode});
      ShelfViewStore.instance.resetForTest();
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('shelf-view-$storage')),
        findsOneWidget,
        reason: '$mode 容器',
      );
      final hasShelf = mode == 'shelf' || mode == 'shelfGrid';
      expect(
        find.byKey(const ValueKey('archive-shelf-carousel')),
        hasShelf ? findsOneWidget : findsNothing,
        reason: '$mode 立体书架',
      );
      if (mode == 'list') {
        expect(find.byKey(const ValueKey('shelf-book-book:a')), findsOneWidget);
      }
      if (mode == 'grid') {
        expect(
          find.byKey(const ValueKey('shelf-grid-book-book:a')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('排序：最近阅读 / 最近加入 / 书名', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('a', title: '甲书'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await ShelfStore.instance.add(_item('c', title: '丙书'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await ShelfStore.instance.add(_item('b', title: '乙书'));
      await LibraryStore.instance.addHistory({
        'id': 'a',
        'kind': 'book',
        'title': '甲书',
        'episode': 0,
        'progress': 0.2,
        'time': DateTime.now().millisecondsSinceEpoch,
      });
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // 默认最近阅读：有阅读记录的 a 在最前。
    expect(_order(tester), ['a', 'b', 'c']);

    await _chooseFilter(tester, 'shelf-filter-sort-recentAdded');
    expect(_order(tester), ['b', 'c', 'a']);

    await _chooseFilter(tester, 'shelf-filter-sort-title');
    expect(_order(tester), ['c', 'b', 'a']);

    await _chooseFilter(tester, 'shelf-filter-sort-recentRead');
    expect(_order(tester), ['a', 'b', 'c']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('阅读状态筛选：未读 / 阅读中 / 已读完', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('unread', title: '未读的书'));
      await ShelfStore.instance.add(_item('reading', title: '在读的书'));
      await ShelfStore.instance.add(_item('done', title: '读完的书'));
      await LibraryStore.instance.addHistory({
        'id': 'reading',
        'kind': 'book',
        'title': '在读的书',
        'episode': 0,
        'chapterCount': 10,
        'progress': 0.3,
        'time': DateTime.now().millisecondsSinceEpoch,
      });
      await LibraryStore.instance.addHistory({
        'id': 'done',
        'kind': 'book',
        'title': '读完的书',
        'episode': 9,
        'chapterCount': 10,
        'progress': 1.0,
        'time': DateTime.now().millisecondsSinceEpoch,
      });
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _chooseFilter(tester, 'shelf-filter-reading-unread');
    expect(_rowKeys(tester), ['shelf-book-book:unread']);

    await _chooseFilter(tester, 'shelf-filter-reading-reading');
    expect(_rowKeys(tester), ['shelf-book-book:reading']);

    await _chooseFilter(tester, 'shelf-filter-reading-finished');
    expect(_rowKeys(tester), ['shelf-book-book:done']);

    await _chooseFilter(tester, 'shelf-filter-reading-all');
    expect(_rowKeys(tester), hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('来源筛选：本地导入 / 在线收藏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('local_1_ab', title: '本地导入的书'));
      await ShelfStore.instance.add(_item('online', title: '在线收藏的书'));
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _chooseFilter(tester, 'shelf-filter-source-local');
    expect(_rowKeys(tester), ['shelf-book-book:local_1_ab']);

    await _chooseFilter(tester, 'shelf-filter-source-online');
    expect(_rowKeys(tester), ['shelf-book-book:online']);

    await _chooseFilter(tester, 'shelf-filter-source-all');
    expect(_rowKeys(tester), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('分类筛选与空分类清除筛选', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late String group;
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('a', title: '甲书'));
      await ShelfStore.instance.add(_item('b', title: '乙书'));
      group = await ShelfGroupStore.instance.addGroup('想读');
      await ShelfGroupStore.instance.assignKeys(['book:a'], group);
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _chooseCategory(tester, '想读');
    expect(_rowKeys(tester), ['shelf-book-book:a']);

    // 空分类：给「清除筛选」出口，点掉后恢复全部。
    await tester.runAsync(() => ShelfGroupStore.instance.addGroup('空分类'));
    await tester.pumpAndSettle();
    await _chooseCategory(tester, '空分类');
    expect(find.text('没有符合筛选的书籍'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shelf-clear-filters')));
    await tester.pumpAndSettle();
    expect(_rowKeys(tester), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑态冻结立体书架拖拽并进入选择模式', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    setSingleChapterPrefs({'shelfLayout': 'shelf'});
    ShelfViewStore.instance.resetForTest();
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('a', title: '甲书'));
      await ShelfStore.instance.add(_item('b', title: '乙书'));
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final carousel = find.byType(ArchiveFileCarousel);
    expect(carousel, findsOneWidget);
    await tester.longPress(carousel);
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 本'), findsOneWidget);
    final widget = tester.widget<ArchiveFileCarousel>(carousel);
    expect(widget.interactive, isFalse);
    expect(widget.selecting, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下拉刷新入口存在', (tester) async {
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('a', title: '甲书'));
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });
}

List<String> _order(WidgetTester tester) {
  final entries = <(double, String)>[];
  for (final id in ['a', 'b', 'c']) {
    final finder = find.byKey(ValueKey('shelf-book-book:$id'));
    if (finder.evaluate().isEmpty) continue;
    entries.add((tester.getTopLeft(finder).dy, id));
  }
  entries.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final entry in entries) entry.$2];
}

List<String> _rowKeys(WidgetTester tester) {
  final keys = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    // Row keys live on the tile widgets, not on text; walk the render tree.
    element.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<String> && key.value.startsWith('shelf-book-')) {
        keys.add(key.value);
        return false;
      }
      return true;
    });
  }
  return keys.toSet().toList();
}

Future<void> _chooseFilter(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(const Key('shelf-filter')));
  await tester.pumpAndSettle();
  final option = find.byKey(Key(key));
  await tester.ensureVisible(option);
  await tester.pumpAndSettle();
  await tester.tap(option);
  await tester.pumpAndSettle();
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

Future<void> _chooseCategory(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const Key('shelf-category')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

Widget _app() => const MaterialApp(home: LibraryPage());

MediaItem _item(String id, {String? title, String kind = 'book'}) => MediaItem(
  id: id,
  title: title ?? id,
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '120',
  kind: kind,
);
