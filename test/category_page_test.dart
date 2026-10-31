import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/category_front.dart';
import 'package:fqapp/pages/category_page.dart';
import 'package:fqapp/services/app_theme.dart' show einkModeNotifier;
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_feed_states.dart';

/// 官方 7.0.9.32 分类页形态：顶部频道 tab + 左侧维度栏 + 右侧分组堆叠的
/// 等宽 chip 网格（手机三列，桌面按宽度加列）。左栏点击滚动定位分组，滚动
/// 反向同步高亮；>30 的组组头右端出「展开/收起」；频道切换重新请求。
void main() {
  CategoryFront front() => CategoryFront.fromPayload({
    'code': 0,
    'data': {
      'rule': {
        'tab': [
          {'name': '出版', 'value': '4'},
          {'name': '男生', 'value': '1'},
          {'name': '女生', 'value': '2'},
        ],
        'dim': [
          {'name': '全部', 'value': '0'},
          {'name': '主题', 'value': '1048576'},
          {'name': '角色', 'value': '3145728'},
        ],
      },
      'down_category': [
        {'name': '都市', 'dim': '1048576', 'id': '1', 'tag': 1},
        {'name': '玄幻', 'dim': '1048576', 'id': '2'},
        {'name': '女帝', 'dim': '3145728', 'id': '3'},
      ],
    },
  });

  Future<void> pump(WidgetTester tester, CategoryFront f) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(home: CategoryPage(loader: ({int tab = 1}) async => f)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders top tabs, dim rail and stacked sections', (
    tester,
  ) async {
    await pump(tester, front());

    // 顶部频道按 value 排序：男生(1)/女生(2)/出版(4)。
    expect(find.byKey(const ValueKey('category_tab_1')), findsOneWidget);
    expect(find.text('男生'), findsOneWidget);
    expect(find.text('出版'), findsOneWidget);
    // 左栏三组：热门标签/主题/角色。
    expect(find.byKey(const ValueKey('category_dim_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('category_dim_1')), findsOneWidget);
    // 右侧分组堆叠：首组=全量瓦片，其余 dim 各一组，「都市」在
    // 热门标签组和主题组各出现一次。
    expect(find.text('热门标签'), findsWidgets);
    expect(find.byKey(const ValueKey('category_tile_1_都市')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('category_tile_3_女帝')), findsNWidgets(2));
  });

  testWidgets('chips form a 3-column equal-width grid', (tester) async {
    await pump(tester, front());

    // 首组 3 颗 chip 在同一行（同一 top）、等宽、列距 7。
    final rects = [
      for (final id in const ['1_都市', '2_玄幻', '3_女帝'])
        tester.getRect(find.byKey(ValueKey('category_tile_$id')).first),
    ];
    expect(rects[0].top, closeTo(rects[1].top, 0.5));
    expect(rects[1].top, closeTo(rects[2].top, 0.5));
    expect(rects[0].width, closeTo(rects[1].width, 0.5));
    expect(rects[1].width, closeTo(rects[2].width, 0.5));
    expect(rects[1].left - rects[0].right, closeTo(7, 0.5));
    expect(rects[2].left - rects[1].right, closeTo(7, 0.5));
    // 官方 chip 定高 30dp（上6下4 边距在 Padding 上，不含在 rect 内）。
    expect(rects[0].height, 30);
  });

  testWidgets('a desktop-width viewport adds columns instead of stretching', (
    tester,
  ) async {
    // 1280 窗口：内容区 1280 − 88(维度栏) − 32(padding) = 1160dp，
    // 按每颗 170dp 目标是 6 列、每颗约 187dp。死守三列会拉到约 380dp。
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(home: CategoryPage(loader: ({int tab = 1}) async => front())),
    );
    await tester.pumpAndSettle();

    final rects = [
      for (final id in const ['1_都市', '2_玄幻', '3_女帝'])
        tester.getRect(find.byKey(ValueKey('category_tile_$id')).first),
    ];
    // 前三颗仍在同一行、等宽。
    expect(rects[0].top, closeTo(rects[1].top, 0.5));
    expect(rects[1].top, closeTo(rects[2].top, 0.5));
    expect(rects[1].width, closeTo(rects[0].width, 0.5));
    // 每颗是对半切（约 187dp），不是铺满整宽（那会是 ~380dp）。
    expect(rects[0].width, lessThan(220));
    expect(rects[0].width, greaterThan(160));
  });

  testWidgets('rail tap scrolls to the section and highlights it', (
    tester,
  ) async {
    // 两组各 35 颗 → 收起态每组 440dp，总高 880 > 800 视口，可滚动。
    final f = CategoryFront.fromPayload({
      'code': 0,
      'data': {
        'rule': {
          'tab': [
            {'name': '男生', 'value': '1'},
          ],
          'dim': [
            {'name': '全部', 'value': '0'},
            {'name': '主题', 'value': '1048576'},
          ],
        },
        'down_category': [
          for (var i = 0; i < 35; i++) {'name': '甲$i', 'dim': '0', 'id': 'a$i'},
          for (var i = 0; i < 35; i++)
            {'name': '乙$i', 'dim': '1048576', 'id': 'b$i'},
        ],
      },
    });
    await pump(tester, f);

    Text railText(String key) => tester.widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Text),
      ),
    );
    // 初始：首项选中橙、次项黑。
    expect(railText('category_dim_0').style?.color, HomePalette.accent);
    expect(railText('category_dim_1').style?.color, isNot(HomePalette.accent));

    await tester.tap(find.byKey(const ValueKey('category_dim_1')));
    await tester.pumpAndSettle();

    // 点击后：高亮切换 + 滚动定位到第二组（内容超出视口才有偏移）。
    expect(railText('category_dim_1').style?.color, HomePalette.accent);
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('category_tile_list')),
    );
    expect(list.controller!.offset, greaterThan(0));
  });

  testWidgets('switching the channel refetches', (tester) async {
    var requestedTab = 1;
    final f = front();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: CategoryPage(
          loader: ({int tab = 1}) async {
            requestedTab = tab;
            return f;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('category_tab_2')));
    await tester.pumpAndSettle();

    expect(requestedTab, 2);
  });

  testWidgets('a channel switch during an in-flight load is not dropped', (
    tester,
  ) async {
    final pending = <int, Completer<CategoryFront>>{};
    final requested = <int>[];
    CategoryFront named(String tile) => CategoryFront.fromPayload({
      'code': 0,
      'data': {
        'rule': {
          'tab': [
            {'name': '男生', 'value': '1'},
            {'name': '女生', 'value': '2'},
            {'name': '出版', 'value': '4'},
          ],
          'dim': [
            {'name': '全部', 'value': '0'},
          ],
        },
        'down_category': [
          {'name': tile, 'dim': '0', 'id': '1'},
        ],
      },
    });

    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: CategoryPage(
          loader: ({int tab = 1}) {
            requested.add(tab);
            return (pending[tab] = Completer<CategoryFront>()).future;
          },
        ),
      ),
    );
    pending[1]!.complete(named('tab1'));
    await tester.pump();

    // 上一个请求还挂着时连切两个频道：旧实现会静默丢掉第二次点击。
    await tester.tap(find.byKey(const ValueKey('category_tab_2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('category_tab_4')));
    await tester.pump();
    expect(requested, [1, 2, 4]);

    // 新频道先回、旧频道后回：旧结果不能覆盖新频道的内容。
    pending[4]!.complete(named('tab4'));
    await tester.pump();
    pending[2]!.complete(named('tab2'));
    await tester.pump();

    expect(find.text('tab4'), findsOneWidget);
    expect(find.text('tab2'), findsNothing);
  });

  testWidgets('a failed load clears the spinner so retry refetches', (
    tester,
  ) async {
    var attempts = 0;
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: CategoryPage(
          loader: ({int tab = 1}) async {
            attempts++;
            if (attempts == 1) throw StateError('offline');
            return front();
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 失败后不能卡在 loading：旧实现里重试会被 `_loading` 直接吞掉。
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('加载失败，请稍后重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();

    expect(attempts, 2);
    expect(find.byKey(const ValueKey('category_tile_1_都市')), findsWidgets);
  });

  testWidgets('超过 30 个标签折叠，组头展开键切全量', (tester) async {
    final f = CategoryFront.fromPayload({
      'code': 0,
      'data': {
        'rule': {
          'tab': [
            {'name': '男生', 'value': '1'},
          ],
          'dim': [
            {'name': '全部', 'value': '0'},
          ],
        },
        'down_category': [
          for (var i = 0; i < 42; i++) {'name': '标签$i', 'dim': '0', 'id': '$i'},
        ],
      },
    });
    await pump(tester, f);

    // 收起：显示 30 个，组头右端有展开键（无需滚动）。
    expect(find.byKey(const ValueKey('category_tile_30_标签30')), findsNothing);
    expect(find.text('展开'), findsOneWidget);
    expect(find.text('标签29'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('category_expand_toggle_0')).hitTestable(),
    );
    await tester.pumpAndSettle();

    // 展开：全量 42 个 + 收起键。
    expect(find.text('标签41'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('热门标签(tag=1)的 chip 带火苗图标', (tester) async {
    await pump(tester, front());
    // 「都市」出现两组各一次，两处都带图标。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('category_tile_1_都市')),
        matching: find.byType(Icon),
      ),
      findsNWidgets(2),
    );
    // 玄幻(tag=0) 无图标。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('category_tile_2_玄幻')),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
  });

  testWidgets('an empty payload shows the error view with retry', (
    tester,
  ) async {
    await pump(tester, CategoryFront.empty);

    expect(find.textContaining('分类暂时没有内容'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(HomeStateView), findsOneWidget);
  });

  testWidgets('墨水屏：官方灰橙退化为纯黑白', (tester) async {
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    await pump(tester, front());

    Text tabText(String value) => tester.widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('category_tab_$value')),
        matching: find.byType(Text),
      ),
    );
    // 顶部频道：选中/未选都退化为纯黑，层级只靠字重。
    expect(tabText('1').style?.color, Colors.black);
    expect(tabText('2').style?.color, Colors.black);
    // 左栏选中/未选都退化为黑字；选中必须另有可见差异：加粗 + 左侧黑指示条。
    Text railText(String key) => tester.widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Text),
      ),
    );
    final selectedRail = railText('category_dim_0');
    final plainRail = railText('category_dim_1');
    expect(selectedRail.style?.color, Colors.black);
    expect(plainRail.style?.color, Colors.black);
    expect(selectedRail.style?.fontWeight, FontWeight.w700);
    expect(plainRail.style?.fontWeight, isNot(FontWeight.w700));
    final selectedBox = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('category_dim_0')),
            matching: find.byType(Container),
          )
          .first,
    );
    final selectedBorder =
        (selectedBox.decoration! as BoxDecoration).border! as Border;
    expect(selectedBorder.left.color, Colors.black);
    expect(selectedBorder.left.width, 2);
    final plainBox = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('category_dim_1')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(plainBox.decoration, isNull);
    // 组头灰字也变黑。
    final header = tester
        .widgetList<Text>(find.text('热门标签'))
        .firstWhere((text) => text.style?.fontSize == 12);
    expect(header.style?.color, Colors.black);
    // chip 灰底变白底 + 黑描边。
    final chip = tester.widget<Container>(
      find.byKey(const ValueKey('category_tile_1_都市')).first,
    );
    final decoration = chip.decoration! as BoxDecoration;
    expect(decoration.color, Colors.white);
    expect((decoration.border! as Border).top.color, Colors.black);
  });

  testWidgets('底部安全区计入内容列表与维度栏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(bottom: 24)),
          child: CategoryPage(loader: ({int tab = 1}) async => front()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('category_tile_list')),
    );
    expect(list.padding, const EdgeInsets.fromLTRB(16, 0, 16, 40));
    // 左栏也有 24 的底部留白，最后一项不会被手势条压住。
    final railPadding = tester
        .widgetList<ListView>(find.byType(ListView))
        .map((view) => view.padding)
        .whereType<EdgeInsets>()
        .any((padding) => padding.bottom == 24);
    expect(railPadding, isTrue);
  });

  test('payload parser keeps the legacy shapes', () {
    final f = front();
    // rule.tab 的 4 频道 + 官方尾部静态补的 短剧/漫画。
    expect(f.tabs.map((t) => t.name), ['男生', '女生', '出版', '短剧', '漫画']);
    expect(f.tabs.map((t) => t.value), ['1', '2', '4', '6', '5']);
    expect(f.dims.map((d) => d.name), ['全部', '主题', '角色']);
    expect(f.tiles, hasLength(3));
    expect(f.tiles.last.dim, '3145728');
  });
}
