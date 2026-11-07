import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/shelf/shelf_collection_view.dart';
import 'package:fqapp/widgets/wenku/book_collection_layout.dart';
import 'package:fqapp/widgets/wenku/wenku_theme.dart';

Widget _host(Widget child, {double width = 360}) => MaterialApp(
  theme: WenkuTheme.create(Brightness.light),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, height: 800, child: child),
    ),
  ),
);

ShelfCollectionView _view({
  required BookCollectionMode mode,
  int itemCount = 3,
  Widget? carousel,
  List<int>? indices,
  double? maxContentWidth,
}) => ShelfCollectionView(
  mode: mode,
  density: const BookGridDensity.auto(),
  itemCount: itemCount,
  regionToolbar: const Text('region-toolbar'),
  carousel: carousel,
  itemBuilder: (context, index) {
    indices?.add(index);
    return SizedBox(height: 80, child: Text('item-$index'));
  },
  emptyBuilder: (_) => const Text('empty-state'),
  padding: EdgeInsets.zero,
  maxContentWidth: maxContentWidth,
);

void main() {
  testWidgets('四种模式映射到列表 / 宫格容器', (tester) async {
    for (final mode in BookCollectionMode.values) {
      await tester.pumpWidget(_host(_view(mode: mode)));
      await tester.pumpAndSettle();
      final collection = tester.widget<BookCollectionView>(
        find.byType(BookCollectionView),
      );
      expect(collection.grid, mode.isGrid, reason: mode.name);
    }
  });

  testWidgets('只有立体书架模式渲染车架', (tester) async {
    for (final mode in BookCollectionMode.values) {
      await tester.pumpWidget(
        _host(
          _view(
            mode: mode,
            carousel: const SizedBox(
              key: Key('archive-shelf-carousel'),
              height: 100,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('archive-shelf-carousel')),
        mode.hasShelf ? findsOneWidget : findsNothing,
        reason: mode.name,
      );
    }
  });

  testWidgets('空表直接渲染工具条与空态，不经过 BookCollectionView', (tester) async {
    await tester.pumpWidget(
      _host(_view(mode: BookCollectionMode.shelfList, itemCount: 0)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BookCollectionView), findsNothing);
    expect(find.text('region-toolbar'), findsOneWidget);
    expect(find.text('empty-state'), findsOneWidget);
  });

  testWidgets('工具条、车架、条目的 sliver 顺序固定', (tester) async {
    await tester.pumpWidget(
      _host(
        _view(
          mode: BookCollectionMode.shelfList,
          carousel: const SizedBox(
            key: Key('archive-shelf-carousel'),
            height: 100,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toolbarY = tester.getTopLeft(find.text('region-toolbar')).dy;
    final carouselY = tester
        .getTopLeft(find.byKey(const Key('archive-shelf-carousel')))
        .dy;
    final itemY = tester.getTopLeft(find.text('item-0')).dy;
    expect(carouselY, greaterThan(toolbarY));
    expect(itemY, greaterThan(carouselY));
  });

  testWidgets('默认物理效果始终可滚动', (tester) async {
    await tester.pumpWidget(_host(_view(mode: BookCollectionMode.list)));
    await tester.pumpAndSettle();
    final scroll = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scroll.physics, isA<AlwaysScrollableScrollPhysics>());
  });

  testWidgets('条目构建器收到从 0 开始的条目下标', (tester) async {
    final indices = <int>[];
    await tester.pumpWidget(
      _host(_view(mode: BookCollectionMode.list, indices: indices)),
    );
    await tester.pumpAndSettle();
    expect(indices, [0, 1, 2]);
  });

  testWidgets('maxContentWidth 在宽屏上居中内容', (tester) async {
    await tester.pumpWidget(
      _host(
        _view(mode: BookCollectionMode.list, maxContentWidth: 400),
        width: 800,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('item-0')).dx,
      greaterThanOrEqualTo(200),
    );
  });
}
