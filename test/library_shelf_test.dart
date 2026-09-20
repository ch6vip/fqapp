import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-shelf-test-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    // A page that is still mounted keeps listeners on the boxes, which can stop
    // Hive.close() from ever settling. The widget tests unmount first (they
    // register their own addTearDown); this bound is the backstop so a run can
    // never end up hanging forever.
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temp dirs live under the system temp folder; a failed cleanup is noise.
    }
  });

  group('ShelfStore', () {
    test('加入的条目按加入时间倒序返回并保留卡片字段', () async {
      final store = ShelfStore.instance;
      await store.add(_item('first', title: '第一本'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.add(_item('second', title: '第二本'));

      final records = store.records();
      expect(records.map((record) => record.item.id), ['second', 'first']);
      expect(records.first.item.title, '第二本');
      expect(records.first.item.kind, 'book');
      expect(records.first.addedAt.isAfter(records.last.addedAt), isTrue);
      expect(store.contains('book', 'first'), isTrue);
      expect(store.containsItem(_item('missing')), isFalse);
    });

    test('toggle 在加入与移出之间切换，removeKeys 只删指定条目', () async {
      final store = ShelfStore.instance;
      expect(await store.toggle(_item('a')), isTrue);
      expect(store.containsItem(_item('a')), isTrue);
      expect(await store.toggle(_item('a')), isFalse);
      expect(store.records(), isEmpty);

      await store.add(_item('a'));
      await store.add(_item('b'));
      await store.removeKeys([ShelfStore.keyOf(_item('a'))]);
      expect(store.records().map((record) => record.item.id), ['b']);
      await store.clear();
      expect(store.records(), isEmpty);
    });

    test('短剧用剧集 ID 作为书架 key，同一部剧只存一条', () async {
      final store = ShelfStore.instance;
      await store.add(_item('episode-1', kind: 'video', seriesId: 'series-9'));
      await store.add(_item('episode-2', kind: 'video', seriesId: 'series-9'));
      expect(store.records(), hasLength(1));
      expect(ShelfStore.keyOf(_item('x', kind: 'video', seriesId: 'series-9')),
          ShelfStore.keyFor('video', 'series-9'));
    });

    test('损坏的记录不会带崩书架', () async {
      final box = Hive.box<dynamic>(ShelfStore.boxName);
      await box.put('broken', 'not a record');
      await box.put('half', {'title': '只有标题'});
      final records = ShelfStore.instance.records();
      expect(records, hasLength(1));
      expect(records.single.item.title, '只有标题');
    });
  });

  group('LibraryPage', () {
    testWidgets('书架 tab 读本地收藏，浏览历史 tab 读阅读历史', (tester) async {
      // 真实的 Hive 文件 I/O 只能在真实异步区里完成：testWidgets 的测试体跑在
      // fake async 区，直接 await store 会永久挂住整份测试。
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('shelf-book', title: '书架里的书'));
        await LibraryStore.instance.addHistory({
          'id': 'history-book',
          'kind': 'book',
          'title': '历史里的书',
          'episode': 3,
          'progress': 0.5,
          'time': DateTime.now().millisecondsSinceEpoch,
        });
      });

      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.text('书架里的书'), findsWidgets);
      expect(find.text('历史里的书'), findsNothing);
      // 书架 tab 有官方页头。
      expect(find.text('今日已读0分钟'), findsOneWidget);

      await tester.tap(find.text('浏览历史'));
      await tester.pumpAndSettle();
      expect(find.text('历史里的书'), findsWidgets);
      expect(find.text('书架里的书'), findsNothing);
      expect(find.text('第4章 · 50%'), findsWidgets);
    });

    testWidgets('书架按最近阅读排序，没有阅读记录的按加入时间', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('old', title: '先加入的'));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await ShelfStore.instance.add(_item('new', title: '后加入的'));
        // 'old' 有更新的阅读时间，应该排到最前面。
        await LibraryStore.instance.addHistory({
          'id': 'old',
          'kind': 'book',
          'title': '先加入的',
          'episode': 1,
          'progress': 0.2,
          'time': DateTime.now().millisecondsSinceEpoch,
        });
      });

      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      final first = tester.getTopLeft(
        find.byKey(const ValueKey('shelf-grid-book:old')),
      );
      final second = tester.getTopLeft(
        find.byKey(const ValueKey('shelf-grid-book:new')),
      );
      expect(first.dx, lessThan(second.dx));
    });

    testWidgets('三种版式可以切换并把偏好写进 SharedPreferences', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('shelf-book'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shelf-grid-view')), findsOneWidget);

      await _chooseLayout(tester, 'switchDouble');
      expect(find.byKey(const Key('shelf-double-view')), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getInt('bookshelf_layout'),
        1,
      );

      await _chooseLayout(tester, 'switchList');
      expect(find.byKey(const Key('shelf-list-view')), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getInt('bookshelf_layout'),
        2,
      );

      await _chooseLayout(tester, 'switchGrid');
      expect(find.byKey(const Key('shelf-grid-view')), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getInt('bookshelf_layout'),
        0,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('旧的列数偏好迁移成宫格并回写', (tester) async {
      SharedPreferences.setMockInitialValues({'bookshelf_layout': 4});
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('shelf-book'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shelf-grid-view')), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getInt('bookshelf_layout'),
        0,
      );
    });

    testWidgets('无效的旧偏好退回宫格且不写坏偏好', (tester) async {
      SharedPreferences.setMockInitialValues({'bookshelf_layout': 'compact'});
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('shelf-book'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shelf-grid-view')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        (await SharedPreferences.getInstance()).get('bookshelf_layout'),
        'compact',
      );
    });

    testWidgets('已保存的列表偏好直接生效', (tester) async {
      SharedPreferences.setMockInitialValues({'bookshelf_layout': 2});
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('shelf-book'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shelf-list-view')), findsOneWidget);
    });

    testWidgets('编辑态可以全选并移出书架', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('a', title: '甲书'));
        await ShelfStore.instance.add(_item('b', title: '乙书'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shelf-edit-button')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 0 本'), findsOneWidget);
      // 未选中任何条目时底栏不可点。
      expect(find.byKey(const Key('shelf-remove-action')), findsOneWidget);

      await tester.tap(find.byKey(const Key('shelf-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 本'), findsOneWidget);

      // 页面发起的 Hive 写必须在真实异步区里起步：真实文件 I/O 只在真实事件
      // 循环上推进，而 testWidgets 的测试体在 fake async 区里，写完成后的延续
      // 不会续跑 —— 那会把 store 的串行写队列卡住，并把后面的用例一起拖死。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('shelf-remove-action')));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('移出'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();


      expect(ShelfStore.instance.records(), isEmpty);
      expect(find.text('书架暂无书籍'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('编辑态点按条目多选，完成后回到浏览态', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('a', title: '甲书'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // 编辑态之外点按会打开详情页，这里只验证编辑态的多选。
      await tester.tap(find.byKey(const Key('shelf-edit-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shelf-grid-book:a')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shelf-edit-done')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsNothing);
      expect(find.byKey(const Key('shelf-edit-button')), findsOneWidget);
    });

    testWidgets('筛选面板按内容类型过滤书架', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('a', title: '小说条目'));
        await ShelfStore.instance.add(
          _item('b', kind: 'video', title: '短剧条目'),
        );
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shelf-grid-book:a')), findsOneWidget);
      expect(find.byKey(const ValueKey('shelf-grid-video:b')), findsOneWidget);

      await tester.tap(find.byKey(const Key('shelf-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shelf-filter-video')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shelf-grid-book:a')), findsNothing);
      expect(find.byKey(const ValueKey('shelf-grid-video:b')), findsOneWidget);

      // 过滤后没有结果时用官方通用空态文案。
      await tester.tap(find.byKey(const Key('shelf-filter-manga')));
      await tester.pumpAndSettle();
      expect(find.text('未找到相关内容'), findsOneWidget);
      expect(find.text('书架暂无书籍'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空书架显示官方文案，去书城找书回调首页', (tester) async {
      var browsed = false;
      await tester.pumpWidget(_app(onBrowse: () => browsed = true));
      await tester.pumpAndSettle();
      expect(find.text('书架暂无书籍'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shelf-browse-button')));
      expect(browsed, isTrue);
    });

    testWidgets('空的浏览历史用官方空态文案', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('浏览历史'));
      await tester.pumpAndSettle();
      expect(find.text('未找到相关内容'), findsOneWidget);
    });

    testWidgets('浏览历史编辑态的删除会清空本地历史', (tester) async {
      await tester.runAsync(() async {
        await LibraryStore.instance.addHistory({
          'id': 'history-book',
          'kind': 'book',
          'title': '历史里的书',
          'time': DateTime.now().millisecondsSinceEpoch,
        });
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('浏览历史'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('history-edit-button')));
      await tester.pumpAndSettle();
      // 底栏动作在没有选中项时是禁用的，先全选再删。
      await tester.tap(find.byKey(const Key('shelf-select-all')));
      await tester.pumpAndSettle();
      // 同上：页面发起的清空写在真实异步区里起步。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('history-delete-action')));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('不支持单条删除'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('清空'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await _settlePageWrite(
        tester,
        () => LibraryStore.instance.historySnapshot().isEmpty,
      );
      expect(LibraryStore.instance.historySnapshot(), isEmpty);
      expect(find.text('未找到相关内容'), findsOneWidget);
    });

    testWidgets('页头显示今日已读分钟数', (tester) async {
      await tester.runAsync(() async {
        await LibraryStore.instance.accumulateReadTime('book-1', 'book', 600);
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.text('今日已读10分钟'), findsOneWidget);
    });

    testWidgets('更多菜单保留清空历史与离线缓存', (tester) async {
      await tester.runAsync(() async {
        await LibraryStore.instance.addHistory({
          'id': 'history-book',
          'kind': 'book',
          'title': '历史里的书',
          'time': DateTime.now().millisecondsSinceEpoch,
        });
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('library-more-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('library-menu-cachedBooks')), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('library-menu-clearHistory')));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('清空'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await _settlePageWrite(
        tester,
        () => LibraryStore.instance.historySnapshot().isEmpty,
      );
      expect(LibraryStore.instance.historySnapshot(), isEmpty);
      // 搜索入口仍然指向搜索页。
      expect(find.byKey(const Key('library-search-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Waits out a write the *page* started itself (`ShelfStore.removeKeys`,
/// `LibraryStore.clearHistory`).
///
/// A `testWidgets` body runs inside a fake async zone: the page's `await` only
/// resumes when that zone flushes microtasks, while the Hive write it waits for
/// only finishes on the real event loop. Alternating a real turn
/// ([WidgetTester.runAsync]) with a [WidgetTester.pump] lets both halves make
/// progress instead of deadlocking on a single `await`.
Future<void> _settlePageWrite(
  WidgetTester tester,
  bool Function() finished,
) async {
  for (var attempt = 0; attempt < 50 && !finished(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _chooseLayout(WidgetTester tester, String action) async {
  await tester.tap(find.byKey(const Key('library-more-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('library-menu-$action')));
  await tester.pumpAndSettle();
}

Widget _app({VoidCallback? onBrowse}) =>
    MaterialApp(home: LibraryPage(onBrowse: onBrowse));

MediaItem _item(String id, {String? title, String kind = 'book', String? seriesId}) =>
    MediaItem(
      id: id,
      title: title ?? id,
      cover: '',
      author: '测试作者',
      badge: '',
      ep: '120',
      kind: kind,
      seriesId: seriesId,
    );
