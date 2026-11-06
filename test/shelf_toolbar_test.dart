import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/wenku/shelf_toolbar.dart';
import 'package:fqapp/widgets/wenku/wenku_theme.dart';

Widget _host(Widget child, {double width = 360, double textScale = 1}) =>
    MaterialApp(
      theme: WenkuTheme.create(Brightness.light),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 800),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

void main() {
  testWidgets('360dp 下工具条不溢出', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfToolbar(
          category: '全部书籍',
          count: 12,
          activeFilters: 2,
          onCategory: () {},
          onFilter: () {},
          onView: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('筛选 · 12 本'), findsOneWidget);
  });

  testWidgets('窄屏大字号把计数换到第二行', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfToolbar(
          category: '全部书籍',
          count: 12,
          activeFilters: 2,
          onCategory: () {},
          onFilter: () {},
          onView: () {},
        ),
        width: 320,
        textScale: 1.4,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final categoryY = tester.getTopLeft(find.text('全部书籍')).dy;
    final countY = tester.getTopLeft(find.text('筛选 · 12 本')).dy;
    expect(countY, greaterThan(categoryY));
  });

  testWidgets('窄分类通道仍显示文件夹图标（fqapp 没有 compact 作用域）', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfToolbar(
          category: '全部书籍',
          count: 3,
          onCategory: () {},
          showFilter: false,
          showView: false,
        ),
        width: 120,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(CupertinoIcons.folder), findsOneWidget);
  });

  testWidgets('分类 / 筛选 / 视图三个入口保留各自的 Key 与回调', (tester) async {
    var category = 0;
    var filter = 0;
    var view = 0;
    await tester.pumpWidget(
      _host(
        ShelfToolbar(
          category: '全部书籍',
          count: 3,
          categoryKey: const Key('shelf-category'),
          filterKey: const Key('shelf-filter'),
          viewKey: const Key('shelf-view'),
          onCategory: () => category++,
          onFilter: () => filter++,
          onView: () => view++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shelf-category')));
    await tester.tap(find.byKey(const Key('shelf-filter')));
    await tester.tap(find.byKey(const Key('shelf-view')));
    expect(category, 1);
    expect(filter, 1);
    expect(view, 1);
  });

  testWidgets('activeFilters 进入筛选按钮的语义值', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        ShelfToolbar(
          category: '全部书籍',
          count: 3,
          activeFilters: 2,
          filterKey: const Key('shelf-filter'),
          onFilter: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('筛选'), findsOneWidget);
    final semantics = tester.getSemantics(
      find.byKey(const Key('shelf-filter')),
    );
    expect(semantics.value, '2 项筛选');
    handle.dispose();
  });

  testWidgets('区域工具条按标题 / 工具条 / below 的顺序排列', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfRegionToolbar(
          title: '全部书籍',
          category: '全部书籍',
          count: 3,
          below: const Text('below-row'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final titleY = tester.getTopLeft(find.text('全部书籍').first).dy;
    final belowY = tester.getTopLeft(find.text('below-row')).dy;
    expect(belowY, greaterThan(titleY));
  });

  testWidgets('今日已读胶囊常规外观无描边、墨水屏有黑描边', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: WenkuTheme.create(Brightness.light),
        home: const Scaffold(body: ShelfTodayReadingPill(minutes: 0)),
      ),
    );
    await tester.pumpAndSettle();
    var pill = tester.widget<Container>(
      find
          .ancestor(of: find.text('今日已读0分钟'), matching: find.byType(Container))
          .first,
    );
    expect((pill.decoration! as BoxDecoration).border, isNull);

    await tester.pumpWidget(
      MaterialApp(
        theme: WenkuTheme.create(Brightness.light, eink: true),
        home: const Scaffold(body: ShelfTodayReadingPill(minutes: 0)),
      ),
    );
    await tester.pumpAndSettle();
    pill = tester.widget<Container>(
      find
          .ancestor(of: find.text('今日已读0分钟'), matching: find.byType(Container))
          .first,
    );
    final border = (pill.decoration! as BoxDecoration).border;
    expect(border, isNotNull);
    expect((border! as Border).top.color, Colors.black);
  });
}
