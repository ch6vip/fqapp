import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/book_open_preferences.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/connectivity_status.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/lazy_indexed_stack.dart';

import 'support/fakes.dart';

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
      expect(
        ShelfStore.keyOf(_item('x', kind: 'video', seriesId: 'series-9')),
        ShelfStore.keyFor('video', 'series-9'),
      );
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

    testWidgets('有总章数时显示「第 N/M 章」，读完整本显示「共 M 章·已读完」（issue #110）',
        (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('mid-book', title: '读了一半'));
        await ShelfStore.instance.add(_item('done-book', title: '读完了'));
        await LibraryStore.instance.addHistory({
          'id': 'mid-book',
          'kind': 'book',
          'title': '读了一半',
          'episode': 99,
          'chapterCount': 380,
          'progress': 0.26,
          'time': DateTime.now().millisecondsSinceEpoch,
        });
        await LibraryStore.instance.addHistory({
          'id': 'done-book',
          'kind': 'book',
          'title': '读完了',
          'episode': 379,
          'chapterCount': 380,
          'progress': 1.0,
          'time': DateTime.now().millisecondsSinceEpoch,
        });
      });

      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // 总章数多、剩余章数少时，纯百分比会显示 26%/100% 无法区分；
      // 章序号能直接看出还剩多少。
      expect(find.text('第100章 · 共380章'), findsWidgets);
      expect(find.text('共380章·已读完'), findsWidgets);
      expect(tester.takeException(), isNull);
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

      // 无编辑按钮：长按卡片进编辑态（长按会选中该项）。
      await tester.longPress(find.byKey(const ValueKey('shelf-grid-book:a')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsOneWidget);
      // 取消选中后底栏不可点。
      await tester.tap(find.byKey(const ValueKey('shelf-grid-book:a')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 0 本'), findsOneWidget);
      // 未选中任何条目时底栏动作禁用（0 选中）。

      await tester.tap(find.byKey(const Key('shelf-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 本'), findsOneWidget);

      // 页面发起的 Hive 写必须在真实异步区里起步：真实文件 I/O 只在真实事件
      // 循环上推进，而 testWidgets 的测试体在 fake async 区里，写完成后的延续
      // 不会续跑 —— 那会把 store 的串行写队列卡住，并把后面的用例一起拖死。
      //
      // 重设计后「移出书架」不再弹确认对话框（可逆操作勿扰：直接执行 +
      // SnackBar 撤销），所以这里没有确认步骤。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('shelf-remove-action')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await _settlePageWrite(
        tester,
        () => ShelfStore.instance.records().isEmpty,
      );

      expect(ShelfStore.instance.records(), isEmpty);
      expect(find.text('书架暂无书籍'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('移出书架免确认，撤销按原加入时间恢复', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('a', title: '甲书'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // 长按进编辑态时会选中该项，故此处不再点「全选」（那会把它取消掉）。
      await tester.longPress(find.byKey(const ValueKey('shelf-grid-book:a')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('shelf-remove-action')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      // SnackBar 入场只用短 pump 推进：pumpAndSettle 会快进 4s 计时把撤销条冲掉。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(ShelfStore.instance.records(), isEmpty);
      final undo = find.byKey(const Key('shelf-undo-button'));
      expect(undo, findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(undo);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      for (var i = 0; i < 50 && ShelfStore.instance.records().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(ShelfStore.instance.records().map((record) => record.item.id), [
        'a',
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('收藏 tab 只放短剧/漫剧，书架 tab 只放书籍', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('plain-book', title: '架上小说'));
        await ShelfStore.instance.add(
          _item('v1', title: '追的短剧', kind: 'video'),
        );
        await ShelfStore.instance.add(
          _item('m1', title: '追的漫剧', kind: 'manju'),
        );
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // 书架 tab：只有书，视频类不混进来。
      expect(find.text('架上小说'), findsWidgets);
      expect(find.text('追的短剧'), findsNothing);
      expect(find.text('追的漫剧'), findsNothing);

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(find.text('追的短剧'), findsWidgets);
      expect(find.text('追的漫剧'), findsWidgets);
      expect(find.text('架上小说'), findsNothing);

      // 筛选胶囊：短剧只剩 video，漫剧只剩 manju，全部恢复两条都在。
      await tester.tap(find.byKey(const Key('library-collection-filter-video')));
      await tester.pumpAndSettle();
      expect(find.text('追的短剧'), findsWidgets);
      expect(find.text('追的漫剧'), findsNothing);
      await tester.tap(find.byKey(const Key('library-collection-filter-manju')));
      await tester.pumpAndSettle();
      expect(find.text('追的短剧'), findsNothing);
      expect(find.text('追的漫剧'), findsWidgets);
      await tester.tap(find.byKey(const Key('library-collection-filter-all')));
      await tester.pumpAndSettle();
      expect(find.text('追的短剧'), findsWidgets);
      expect(find.text('追的漫剧'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('收藏 tab 编辑态移出：免确认直接执行，书籍不受影响', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('plain-book', title: '架上小说'));
        await ShelfStore.instance.add(
          _item('v1', title: '追的短剧', kind: 'video'),
        );
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const ValueKey('shelf-grid-video:v1')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 部'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('shelf-remove-action')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 短剧已移出，书还在架上。
      expect(
        ShelfStore.instance.records().map((record) => record.item.id),
        ['plain-book'],
      );
      expect(find.text('暂无收藏内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('收藏为空：空态文案随筛选变化，「找短剧」触发回调', (tester) async {
      var findDramaCalls = 0;
      await tester.runAsync(() async {
        await ShelfStore.instance.add(
          _item('v1', title: '追的短剧', kind: 'video'),
        );
      });
      await tester.pumpWidget(_app(onFindDrama: () => findDramaCalls++));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();

      // 有短剧、无漫剧：切到漫剧筛选是「暂无漫剧」+ 找短剧入口。
      await tester.tap(find.byKey(const Key('library-collection-filter-manju')));
      await tester.pumpAndSettle();
      expect(find.text('暂无漫剧'), findsOneWidget);
      await tester.tap(find.byKey(const Key('collection-find-drama-button')));
      await tester.pumpAndSettle();
      expect(findDramaCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('页头只剩今日已读与版式分段：排序/筛选/编辑入口已移除', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('shelf-book'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // 两个控件同排。
      final pill = tester.getCenter(find.text('今日已读0分钟')).dy;
      expect(
        (tester.getCenter(find.byKey(const Key('shelf-layout-grid'))).dy - pill)
            .abs(),
        lessThan(1),
      );

      // 三个入口一个都不该在：排序胶囊、筛选按钮、编辑按钮。
      for (final key in const [
        'shelf-sort-button',
        'shelf-filter-button',
        'shelf-edit-button',
        'history-edit-button',
      ]) {
        expect(find.byKey(Key(key)), findsNothing, reason: '$key 应已移除');
      }
      // 「更多」菜单也不再承载排序项。
      await tester.tap(find.byKey(const Key('library-more-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shelf-sort-added')), findsNothing);
      expect(find.byKey(const Key('shelf-sort-title')), findsNothing);
      expect(find.byKey(const Key('library-menu-switchList')), findsOneWidget);
      // 点遮罩关掉菜单（菜单打开时 library-more-button 被 barrier 盖住）。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏（360dp）下页头一行不溢出', (tester) async {
      // 删掉三个入口后只剩胶囊 + 版式分段（≈253dp），360dp 窄屏一行放得下。
      tester.view.physicalSize = const Size(1080, 2280);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('shelf-book'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final pill = tester.getCenter(find.text('今日已读0分钟')).dy;
      expect(
        (tester.getCenter(find.byKey(const Key('shelf-layout-grid'))).dy - pill)
            .abs(),
        lessThan(1),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('工具栏版式分段控件与更多菜单同源并持久化', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('shelf-book'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shelf-grid-view')), findsOneWidget);

      await tester.tap(find.byKey(const Key('shelf-layout-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shelf-list-view')), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getInt('bookshelf_layout'),
        2,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('编辑态点按条目多选，完成后回到浏览态', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('a', title: '甲书'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // 编辑态之外点按会打开详情页，这里只验证编辑态的多选。
      await tester.longPress(find.byKey(const ValueKey('shelf-grid-book:a')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shelf-edit-done')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsNothing);
      // 回到浏览态：编辑入口只剩长按，页头不再有编辑按钮。
      expect(find.byKey(const Key('shelf-edit-button')), findsNothing);
    });

    testWidgets('编辑态侧滑/返回先退出编辑态，不把整页 pop 掉', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('a', title: '甲书'));
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const ValueKey('shelf-grid-book:a')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsOneWidget);

      // 系统返回（手势/返回键）走 handlePopRoute：编辑态必须拦下它。
      // 书架页不是独立路由而是 RootShell 的 child，不拦就会冒泡到根路由
      // 退掉整个应用 —— 这正是本用例钉住的行为。
      final handled = await TestWidgetsFlutterBinding.instance.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handled, isTrue, reason: '编辑态应拦下系统返回');
      expect(find.text('已选择 1 本'), findsNothing, reason: '返回应退出编辑态');
      expect(find.byKey(const Key('library-more-button')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 回到浏览态后，返回不再被拦（交回给宿主/系统）。
      expect(
        await TestWidgetsFlutterBinding.instance.handlePopRoute(),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('切走时条目被移出书架，回来时选中计数随数据回真', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('keep', title: '留下的'));
        await ShelfStore.instance.add(_item('gone', title: '被移出的'));
      });

      // RootShell 用 LazyIndexedStack 保活书架页：切到别的 tab 只是把页面藏起来
      // （TickerMode 关掉 → 页面的 _visible 变 false），编辑态留在 State 里。
      final index = ValueNotifier<int>(0);
      addTearDown(index.dispose);
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: index,
            builder: (context, value, child) => LazyIndexedStack(
              index: value,
              children: [
                const LibraryPage(),
                const SizedBox.expand(child: Text('其他 tab')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 编辑入口按钮已删除：长按任一卡片进入编辑态（并选中该项）。
      await tester.longPress(
        find.byKey(const ValueKey('shelf-grid-book:keep')),
      );
      await tester.tap(find.byKey(const Key('shelf-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 本'), findsOneWidget);

      // 切走之后，另一条路径（详情页的收藏开关等）把其中一本移出书架。
      index.value = 1;
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await ShelfStore.instance.removeKeys([ShelfStore.keyOf(_item('gone'))]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // 回到书架页：快照重载后，选中集合里那条已经不存在的记录不该继续占着
      // 「已选择 N 本」。
      index.value = 0;
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
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

    testWidgets('浏览历史编辑态的删除会移除选中记录', (tester) async {
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

      // 编辑入口按钮已按用户要求删除：改为长按卡片进入编辑态（并选中该项）。
      await tester.longPress(
        find.byKey(const ValueKey('shelf-grid-book:history-book')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsOneWidget);
      // 同上：页面发起的清空写在真实异步区里起步。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('history-delete-action')));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('无法撤销'), findsOneWidget);
      await tester.runAsync(() async {
        // 底栏动作标签同为「删除」，用控件类型收窄到对话框的确认按钮。
        await tester.tap(find.widgetWithText(FilledButton, '删除'));
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
      expect(find.byKey(const Key('library-menu-importBook')), findsOneWidget);
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

  group('最近阅读缓存直达', () {
    for (final entry in ['首页', '书架']) {
      testWidgets('$entry 缓存续读不经过详情或网络探测，并恢复原章节位置', (tester) async {
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
        BookOpenPreferences.instance.resetForTest();
        final saved = <String, dynamic>{
          'id': 'recent-book',
          'title': '最近读过的书',
          'kind': 'book',
          'chapterId': '2',
          'episode': 0, // 稳定章节 ID 优先于旧下标。
          'position': 300.0,
          'maxScroll': 900.0,
          'progress': 1 / 9,
          'time': DateTime.now().millisecondsSinceEpoch,
        };
        await tester.runAsync(() async {
          await ShelfStore.instance.add(_item('recent-book', title: '最近读过的书'));
          await LibraryStore.instance.addHistory(saved);
        });
        final cache = MemoryChapterCache();
        await cache.saveBook(
          CachedBook(
            id: 'recent-book',
            title: '缓存书名',
            chapters: [
              Chapter(itemId: '1', title: '第一章', volumeName: ''),
              Chapter(itemId: '2', title: '第二章', volumeName: ''),
            ],
          ),
        );
        for (final id in ['1', '2']) {
          await cache.write(
            bookId: 'recent-book',
            chapterId: id,
            title: '章节$id',
            text: List.filled(80, '这是第$id 章缓存正文，用于验证恢复阅读位置。').join('\n\n'),
          );
        }
        final readerStore = MemoryReaderStore(entry: saved);
        var connectivityChecks = 0;
        await tester.pumpWidget(
          entry == '书架'
              ? _app(
                  cache: cache,
                  readerStore: readerStore,
                  connectivity: () async {
                    connectivityChecks++;
                    return (online: true, metered: false);
                  },
                )
              : ProviderScope(
                  overrides: [
                    homeProvider.overrideWith(
                      () => HomeNotifier(
                        homepageLoader:
                            ({
                              int tabType = 2,
                              int offset = 0,
                              String? sessionId,
                            }) async => HomepagePage(
                              items: [_item('recommendation', title: '推荐书')],
                              nextOffset: null,
                              sessionId: null,
                            ),
                        searchLoader: (query, {int page = 1}) async => [],
                      ),
                    ),
                  ],
                  child: MaterialApp(
                    home: HomePage(cacheStore: cache, readerStore: readerStore),
                  ),
                ),
        );
        await tester.pumpAndSettle();
        // 首页把在读的书收进顶部「继续阅读」一行（书名和章节同一行文案），
        // 书架仍是带封面的条目；两边用各自的入口点进阅读页。
        final recent = entry == '书架'
            ? find.text('最近读过的书')
            : find.byKey(const Key('home_continue_row'));
        await tester.ensureVisible(recent);
        await tester.pumpAndSettle();
        await tester.tap(recent);
        await tester.pumpAndSettle();
        final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
        expect(reader.startIndex, 1);
        expect(reader.title, '最近读过的书');
        expect(reader.localOnly, isFalse);
        expect(find.byType(DetailPage, skipOffstage: false), findsNothing);
        expect(connectivityChecks, 0);
        final controller = tester
            .widget<ListView>(
              find.descendant(
                of: find.byType(ReaderPage),
                matching: find.byType(ListView),
              ),
            )
            .controller!;
        expect(controller.offset, greaterThan(0));
        expect(readerStore.entry?['chapterId'], '2');
        expect(readerStore.entry?['position'], controller.offset);
        expect(
          controller.offset / controller.position.maxScrollExtent,
          closeTo(1 / 3, .01),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('关闭书架直读时即使有最近章节缓存也先看详情', (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      BookOpenPreferences.instance.resetForTest();
      await BookOpenPreferences.instance.setShelfDirectReader(false);
      await tester.runAsync(
        () => ShelfStore.instance.add(_item('cached', title: '有缓存的书')),
      );
      final cache = MemoryChapterCache();
      await cache.write(
        bookId: 'cached',
        chapterId: '1',
        title: '第一章',
        text: '缓存正文',
      );
      await tester.pumpWidget(
        _app(
          cache: cache,
          readerStore: MemoryReaderStore(entry: {'chapterId': '1'}),
          connectivity: () async => (online: true, metered: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('有缓存的书'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(ReaderPage, skipOffstage: false), findsNothing);
      expect(
        tester.widget<DetailPage>(find.byType(DetailPage)).autoOpenReader,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('书架离线直读', () {
    testWidgets('导入章节的小说开启自动续读，普通书籍仍走原入口', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('101', title: '已导入的小说'));
        await LibraryStore.instance.mergeFanqie([
          {
            'id': '101',
            'bookId': '101',
            'kind': 'book',
            'time': 100,
            'chapterId': '202',
            'episode': 1,
            'fanqieImported': true,
          },
        ]);
      });
      await tester.pumpWidget(
        _app(
          cache: MemoryChapterCache(),
          connectivity: () async => (online: false, metered: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('已导入的小说'));
      await tester.pump();
      await tester.pump();
      final detail = tester.widget<DetailPage>(find.byType(DetailPage));
      expect(detail.autoOpenReader, true);
      expect(detail.item.id, '101');
      expect(
        (await LibraryStore.instance.historyEntry('101'))?['chapterId'],
        '202',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('普通书籍默认直达阅读器，关掉书架开关后停在详情页', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('plain', title: '普通小说'));
      });
      // 页面与偏好都是进程级单例：先回到默认值再走一遍设置。
      BookOpenPreferences.instance.resetForTest();
      Future<void> openPlainBook() async {
        await tester.pumpWidget(
          _app(
            cache: MemoryChapterCache(),
            connectivity: () async => (online: false, metered: false),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('普通小说'));
        // 详情页停在加载态（转圈动画不会停），所以等 DetailPage 建出来而不是
        // pumpAndSettle；openBookDetail 先 await 偏好加载，需要真实事件循环的回合。
        for (
          var attempt = 0;
          attempt < 20 &&
              find.byType(DetailPage, skipOffstage: false).evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
      }

      await openPlainBook();
      expect(
        tester
            .widget<DetailPage>(find.byType(DetailPage, skipOffstage: false))
            .autoOpenReader,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());

      await BookOpenPreferences.instance.setShelfDirectReader(false);
      await openPlainBook();
      expect(
        tester
            .widget<DetailPage>(find.byType(DetailPage, skipOffstage: false))
            .autoOpenReader,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('无网且本地有缓存时，点书直接进阅读器而不是详情页', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('offline-book', title: '离线直读的书'));
      });
      final cache = MemoryChapterCache();
      await cache.write(
        bookId: 'offline-book',
        chapterId: '1',
        title: '第一章',
        text: '离线正文',
      );

      await tester.pumpWidget(
        _app(
          cache: cache,
          connectivity: () async => (online: false, metered: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线直读的书'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage, skipOffstage: false), findsOneWidget);
      // 详情页要联网取目录，离线时正是它把「已下载」变成读不了。
      expect(find.byType(DetailPage, skipOffstage: false), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('无网但没有缓存时，仍然走详情页', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item('no-cache-book', title: '没缓存的书'));
      });

      await tester.pumpWidget(
        _app(
          cache: MemoryChapterCache(),
          connectivity: () async => (online: false, metered: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('没缓存的书'));
      // 详情页会去联网取目录，测试宿主里必然失败；这里只验它被推了出来。
      await tester.pump();
      await tester.pump();
      expect(find.byType(DetailPage, skipOffstage: false), findsOneWidget);
      expect(find.byType(ReaderPage, skipOffstage: false), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('空书架给出「查看离线缓存」入口', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.text('书架暂无书籍'), findsOneWidget);
      final entry = find.byKey(const Key('shelf-cached-books-button'));
      expect(entry, findsOneWidget);
      await tester.tap(entry);
      // 缓存页要开真实 Hive box：真实文件 I/O 只在真实事件循环里跑得完，
      // 交替「真实一帧 + pump」直到页面标题出现（同 _settlePageWrite 的做法）。
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.text('离线缓存').evaluate().isNotEmpty) break;
      }
      expect(find.text('离线缓存'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('横向手势在书架一级 tab 之间切换', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('书架暂无书籍'), findsOneWidget);

    await tester.drag(find.byType(LibraryPage), const Offset(-240, 0));
    await tester.pumpAndSettle();
    // 「浏览历史」的空态；书架的空态同时消失，说明确实换了 tab。
    expect(find.text('未找到相关内容'), findsOneWidget);
    expect(find.text('书架暂无书籍'), findsNothing);

    // 往右滑回到「书架」。
    await tester.drag(find.byType(LibraryPage), const Offset(240, 0));
    await tester.pumpAndSettle();
    expect(find.text('书架暂无书籍'), findsOneWidget);
    // 已经在首个 tab 上继续右滑：边界，不环绕到「收藏」。
    await tester.drag(find.byType(LibraryPage), const Offset(240, 0));
    await tester.pumpAndSettle();
    expect(find.text('书架暂无书籍'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
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

Widget _app({
  VoidCallback? onBrowse,
  VoidCallback? onFindDrama,
  ChapterCache? cache,
  ReaderStore? readerStore,
  Future<ConnectivityView> Function()? connectivity,
}) => MaterialApp(
  home: LibraryPage(
    onBrowse: onBrowse,
    onFindDrama: onFindDrama,
    cacheStore: cache,
    readerStore: readerStore,
    connectivity: connectivity,
  ),
);

MediaItem _item(
  String id, {
  String? title,
  String kind = 'book',
  String? seriesId,
}) => MediaItem(
  id: id,
  title: title ?? id,
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '120',
  kind: kind,
  seriesId: seriesId,
);
