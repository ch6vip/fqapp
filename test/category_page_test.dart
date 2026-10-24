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
        {'name': '都市', 'dim': '1048576', 'id': '1'},
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

  testWidgets('an empty payload shows the error view with retry', (
    tester,
  ) async {
    await pump(tester, CategoryFront.empty);

    expect(find.textContaining('分类暂时没有内容'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  test('payload parser keeps the legacy shapes', () {
    final f = front();
    expect(f.tabs.map((t) => t.name), ['男生', '女生', '出版']);
    expect(f.dims.map((d) => d.name), ['全部', '主题', '角色']);
    expect(f.tiles, hasLength(3));
    expect(f.tiles.last.dim, '3145728');
  });
}
