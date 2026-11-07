import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/shelf_view_state.dart';
import 'package:fqapp/widgets/wenku/book_collection_layout.dart';
import 'package:fqapp/widgets/wenku/shelf_options_sheet.dart';
import 'package:fqapp/widgets/wenku/wenku_glass.dart';
import 'package:fqapp/widgets/wenku/wenku_segments.dart';
import 'package:fqapp/widgets/wenku/wenku_theme.dart';

Widget _host(Widget child) => MaterialApp(
  theme: WenkuTheme.create(Brightness.light),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

void main() {
  testWidgets('四种版式都有 Key 并回传所选模式', (tester) async {
    final picked = <BookCollectionMode>[];
    await tester.pumpWidget(
      _host(
        ShelfViewOptions(
          mode: BookCollectionMode.shelfList,
          onModeChanged: picked.add,
          density: const BookGridDensity.auto(),
          onDensityChanged: (_) {},
          onPreferencesChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final mode in BookCollectionMode.values) {
      expect(
        find.byKey(ValueKey('collection-view-${mode.storageValue}')),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const ValueKey('collection-view-list')));
    await tester.tap(find.byKey(const ValueKey('collection-view-shelf')));
    await tester.tap(find.byKey(const ValueKey('collection-view-shelfGrid')));
    await tester.tap(find.byKey(const ValueKey('collection-view-grid')));
    expect(picked, [
      BookCollectionMode.list,
      BookCollectionMode.shelfList,
      BookCollectionMode.shelfGrid,
      BookCollectionMode.grid,
    ]);
  });

  testWidgets('宫格模式显示四个封面密度 Key 并回传', (tester) async {
    final picked = <BookGridDensity>[];
    await tester.pumpWidget(
      _host(
        ShelfViewOptions(
          mode: BookCollectionMode.grid,
          onModeChanged: (_) {},
          density: const BookGridDensity.auto(),
          onDensityChanged: picked.add,
          onPreferencesChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final value in ['auto', 'small', 'medium', 'large']) {
      expect(find.byKey(ValueKey('grid-density-$value')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('grid-density-medium')));
    expect(picked.single, const BookGridDensity.sized(BookGridSize.medium));
  });

  testWidgets('本数输入接受 1–100，越界回退并提示', (tester) async {
    final changes = <BookShelfPreferences>[];
    await tester.pumpWidget(
      _host(
        ShelfViewOptions(
          mode: BookCollectionMode.shelfList,
          onModeChanged: (_) {},
          density: const BookGridDensity.auto(),
          onDensityChanged: (_) {},
          onPreferencesChanged: changes.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('shelf-minimum-books-input'));

    await tester.enterText(input, '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(find.text('请输入 1–100 本'), findsOneWidget);
    // The notice is a root-Overlay notice, not a page-level SnackBar.
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.widget<CupertinoTextField>(input).controller!.text, '1');

    await tester.enterText(input, '101');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(tester.widget<CupertinoTextField>(input).controller!.text, '1');

    await tester.enterText(input, '5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changes.single.minimumBooks, 5);
    // Let the transient notice's timer fire before the test zone ends.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('切换版式时立体参数区与封面密度区按模式展开/收起', (tester) async {
    var mode = BookCollectionMode.shelfList;
    await tester.pumpWidget(
      MaterialApp(
        theme: WenkuTheme.create(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: 360,
                child: ShelfViewOptions(
                  mode: mode,
                  onModeChanged: (value) => setState(() => mode = value),
                  density: const BookGridDensity.auto(),
                  onDensityChanged: (_) {},
                  onPreferencesChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelf-minimum-books')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-density-auto')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('collection-view-grid')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelf-minimum-books')), findsNothing);
    expect(find.byKey(const ValueKey('grid-density-auto')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('collection-view-shelf')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelf-minimum-books')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-density-auto')), findsNothing);
  });

  testWidgets('重复填充开关回传新值', (tester) async {
    final changes = <BookShelfPreferences>[];
    await tester.pumpWidget(
      _host(
        ShelfViewOptions(
          mode: BookCollectionMode.shelfList,
          onModeChanged: (_) {},
          density: const BookGridDensity.auto(),
          onDensityChanged: (_) {},
          onPreferencesChanged: changes.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.descendant(
      of: find.byKey(const ValueKey('shelf-repeat-fill')),
      matching: find.byType(AppGlassSwitch),
    );
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(changes.single.repeatFill, isFalse);
  });

  testWidgets('选项面板不暴露 followCollection 开关', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfViewOptions(
          mode: BookCollectionMode.shelfList,
          onModeChanged: (_) {},
          density: const BookGridDensity.auto(),
          onDensityChanged: (_) {},
          onPreferencesChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('跟随下方分类与排序'), findsNothing);
  });

  testWidgets('shelf 目标只显示立体区参数，collection 目标只显示列表/宫格', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfViewOptions(
          target: ShelfViewTarget.shelf,
          mode: BookCollectionMode.shelfList,
          onModeChanged: (_) {},
          density: const BookGridDensity.auto(),
          onDensityChanged: (_) {},
          onPreferencesChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('collection-view-list')), findsNothing);
    expect(find.byKey(const ValueKey('shelf-minimum-books')), findsOneWidget);

    await tester.pumpWidget(
      _host(
        ShelfViewOptions(
          target: ShelfViewTarget.collection,
          mode: BookCollectionMode.grid,
          onModeChanged: (_) {},
          density: const BookGridDensity.auto(),
          onDensityChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('collection-region-view-false')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('collection-region-view-true')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('grid-density-auto')), findsOneWidget);
  });

  testWidgets('筛选面板包含阅读状态、来源与排序', (tester) async {
    final sorts = <ShelfSort>[];
    await tester.pumpWidget(
      _host(
        ShelfFilterOptions(
          sort: ShelfSort.recentRead,
          reading: ShelfReadingFilter.all,
          source: ShelfSourceFilter.all,
          onSort: sorts.add,
          onReading: (_) {},
          onSource: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('阅读状态'), findsOneWidget);
    expect(find.text('书籍来源'), findsOneWidget);
    expect(find.text('排列顺序'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shelf-filter-sort-title')));
    expect(sorts.single, ShelfSort.title);
  });

  testWidgets('缓存扫描未完成时来源里的已缓存不可选', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfFilterOptions(
          sort: ShelfSort.recentRead,
          reading: ShelfReadingFilter.all,
          source: ShelfSourceFilter.all,
          onSort: (_) {},
          onReading: (_) {},
          onSource: (_) {},
          cachedAvailable: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cached = tester.widget<GlassTextButton>(
      find.byKey(const ValueKey('shelf-filter-source-cached')),
    );
    expect(cached.onPressed, isNull);
  });
}
