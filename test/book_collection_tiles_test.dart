import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/shelf/book_collection_tiles.dart';
import 'package:fqapp/widgets/shelf/shelf_cover_image.dart';
import 'package:fqapp/widgets/wenku/src/app_text.dart';
import 'package:fqapp/widgets/wenku/wenku_theme.dart';

MediaItem _item(
  String id, {
  String kind = 'book',
  String source = 'fanqie',
  String title = '书',
  String author = '作者',
}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: author,
  badge: '',
  ep: '',
  kind: kind,
  source: source,
);

Widget _host(Widget child) => MaterialApp(
  theme: WenkuTheme.create(Brightness.light),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

void main() {
  test('file code 使用 FQ-/SQ- 前缀并可带缓存/导入标记', () {
    expect(archiveFileCode(_item('1')), 'FQ-00001');
    expect(archiveFileCode(_item('1', source: 'shuqi')), 'SQ-00001');
    expect(archiveFileCode(_item('local_1')), 'FQ-local_1');
    expect(archiveFileCode(_item('1'), cached: true), 'FQ-00001 · 缓存');
    expect(
      archiveFileCode(_item('1'), fanqieImported: true),
      'FQ-00001 · 番茄导入',
    );
  });

  testWidgets('列表行显示 56x76 封面、编号、标题、元信息与进度', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfNovelRow(
          item: _item('1', title: '测试书'),
          onTap: () {},
          badge: '更新',
          meta: '作者 · 连载中',
          progress: '第 3 章',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cover = tester.widget<ShelfCoverImage>(find.byType(ShelfCoverImage));
    expect(cover.width, 56);
    expect(cover.height, 76);
    expect(find.text('FQ-00001'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AppText && widget.data == '测试书',
      ),
      findsOneWidget,
    );
    expect(find.text('作者 · 连载中'), findsOneWidget);
    expect(find.text('第 3 章'), findsOneWidget);
    expect(find.text('更新'), findsOneWidget);
  });

  testWidgets('宫格条目封面按 30:41 比例铺满格子', (tester) async {
    await tester.pumpWidget(
      _host(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            child: ShelfBookGridTile(
              item: _item('2', title: '宫格书'),
              onTap: () {},
              meta: '作者',
              progress: '已读完',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cover = tester.widget<ShelfCoverImage>(find.byType(ShelfCoverImage));
    expect(cover.width, 120);
    expect(cover.height, closeTo(120 / (30 / 41), 0.01));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AppText && widget.data == '宫格书',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is AppText && widget.data == '作者',
      ),
      findsOneWidget,
    );
    expect(find.text('已读完'), findsOneWidget);
  });

  testWidgets('列表行底部分隔线使用主题 dividerColor', (tester) async {
    await tester.pumpWidget(
      _host(ShelfNovelRow(item: _item('1'), onTap: () {})),
    );
    await tester.pumpAndSettle();
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(ShelfNovelRow),
            matching: find.byType(Container),
          )
          .first,
    );
    final border = (container.decoration! as BoxDecoration).border! as Border;
    final theme = Theme.of(tester.element(find.byType(ShelfNovelRow)));
    expect(border.bottom.color, theme.dividerColor);
  });

  testWidgets('宫格条目也显示番茄导入标记', (tester) async {
    await tester.pumpWidget(
      _host(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            child: ShelfBookGridTile(
              item: _item('3'),
              onTap: () {},
              meta: '作者',
              fanqieImported: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('作者 · 番茄导入'), findsOneWidget);
  });

  testWidgets('编辑态隐藏封面角标并显示选中标记', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfNovelRow(
          item: _item('1'),
          onTap: () {},
          badge: '更新',
          editing: true,
          selected: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('更新'), findsNothing);
    expect(find.byType(ShelfSelectionMark), findsOneWidget);
  });

  testWidgets('编辑态选中进入语义', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        ShelfNovelRow(
          item: _item('1'),
          onTap: () {},
          editing: true,
          selected: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.byType(ShelfNovelRow));
    expect(node.flagsCollection.isSelected, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('长按进入编辑态', (tester) async {
    var longPressed = 0;
    await tester.pumpWidget(
      _host(
        ShelfNovelRow(
          item: _item('1'),
          onTap: () {},
          onLongPress: () => longPressed++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(ShelfNovelRow));
    expect(longPressed, 1);
  });

  testWidgets('失败条目保留重试入口', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _host(ShelfBookGridFailure(title: '书籍 1 暂未载入', onRetry: () => retried++)),
    );
    await tester.pumpAndSettle();
    expect(find.text('书籍 1 暂未载入'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, 1);
  });
}
