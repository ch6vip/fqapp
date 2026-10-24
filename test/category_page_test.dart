import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/category_front.dart';
import 'package:fqapp/pages/category_page.dart';

/// 官方 7.0.9.32 分类页形态：顶部频道 tab + 左侧维度栏 + 右侧文字 chips。
/// 维度切换是本地过滤；频道切换重新请求。
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

  testWidgets('renders top tabs, dim rail and text chips', (tester) async {
    await pump(tester, front());

    // 顶部频道按 value 排序：男生(1)/女生(2)/出版(4)。
    expect(find.byKey(const ValueKey('category_tab_1')), findsOneWidget);
    expect(find.text('男生'), findsOneWidget);
    expect(find.text('出版'), findsOneWidget);
    // 左栏首项官方写作「热门标签」。
    expect(find.text('热门标签'), findsWidgets);
    expect(find.text('主题'), findsWidgets);
    // 全部维度的 chips 都在。
    expect(find.text('都市'), findsOneWidget);
    expect(find.text('女帝'), findsOneWidget);
  });

  testWidgets('switching the dimension filters tiles locally', (tester) async {
    await pump(tester, front());

    await tester.tap(find.byKey(const ValueKey('category_dim_1')));
    await tester.pumpAndSettle();

    // 主题（dim=1048576）只剩都市/玄幻。
    expect(find.text('都市'), findsOneWidget);
    expect(find.text('女帝'), findsNothing);
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

  testWidgets('超过 30 个标签折叠，展开键切换全量', (tester) async {
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

    // 收起：显示 30 个 + 展开键；第 31 个不可见。
    expect(find.byKey(const ValueKey('category_tile_30_标签30')), findsNothing);
    expect(find.text('展开'), findsOneWidget);
    expect(find.text('标签29'), findsOneWidget);

    // 展开键在 30 个 chip 之后：把内容区拖到底再点。
    await tester.drag(
      find.byKey(const ValueKey('category_tile_list')),
      const Offset(0, -2400),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('category_expand_toggle')).hitTestable(),
    );
    await tester.pumpAndSettle();

    // 展开：全量 42 个 + 收起键。
    expect(find.text('标签41'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('热门标签(tag=1)的 chip 带火苗图标', (tester) async {
    await pump(tester, front());
    final chip = find.byKey(const ValueKey('category_tile_1_都市'));
    expect(
      find.descendant(of: chip, matching: find.byType(Icon)),
      findsOneWidget,
    );
    // 玄幻(tag=0) 无图标。
    final plain = find.byKey(const ValueKey('category_tile_2_玄幻'));
    expect(
      find.descendant(of: plain, matching: find.byType(Icon)),
      findsNothing,
    );
  });

  testWidgets('an empty payload shows the error view with retry', (
    tester,
  ) async {
    await pump(tester, CategoryFront.empty);

    expect(find.textContaining('分类暂时没有内容'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
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
