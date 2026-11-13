import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/bookshelf_card.dart';
import 'package:fqapp/widgets/shelf/shelf_design.dart';

void main() {
  test('每种内容类型都有中文标签', () {
    expect(bookshelfKindLabel('book'), '小说');
    expect(bookshelfKindLabel('video'), '短剧');
    expect(bookshelfKindLabel('audio'), '听书');
    expect(bookshelfKindLabel('manga'), '漫画');
    expect(bookshelfKindLabel('manju'), '漫剧');
    // 未知类型退回原始值，不抛异常。
    expect(bookshelfKindLabel('unknown'), 'unknown');
  });

  testWidgets('宫格封面按 1.4 比例、圆角 10 并带进度角标', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 420,
              child: BookshelfGridCard(
                item: _item('宫格作品'),
                badgeText: '35%',
                infoText: '第12章 · 35%',
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    final cover = tester.getSize(find.byKey(const Key('bookshelf-cover')));
    expect(cover.width, 200);
    expect(cover.height, closeTo(200 * ShelfTokens.gridCoverRatio, 0.01));
    // 圆角走 ShelfTokens.radiusCover（10dp）。
    final clip = tester.widget<ClipRRect>(
      find
          .descendant(
            of: find.byKey(const Key('bookshelf-cover')),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(clip.borderRadius, BorderRadius.circular(ShelfTokens.radiusCover));
    expect(find.text('35%'), findsOneWidget);
    expect(find.text('第12章 · 35%'), findsOneWidget);
    expect(find.text('宫格作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宫格编辑态显示多选框并隐藏角标', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 360,
              child: BookshelfGridCard(
                item: _item('宫格作品'),
                badgeText: '35%',
                editing: true,
                selected: true,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('35%'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('列表条目是 84dp 行高加 56×78 封面', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              BookshelfListCard(
                item: _item('列表作品'),
                progressText: '第12章 · 35%',
                metaText: '测试作者',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(BookshelfListCard)).height,
      ShelfTokens.listRowHeight,
    );
    final cover = tester.getSize(find.byKey(const Key('bookshelf-cover')));
    expect(cover.width, ShelfTokens.listCoverWidth);
    expect(cover.height, ShelfTokens.listCoverHeight);
    // 行内边距走统一的 screenPadding（16dp）。
    final card = tester.getRect(find.byType(BookshelfListCard));
    expect(
      tester.getRect(find.byKey(const Key('bookshelf-cover'))).left - card.left,
      ShelfTokens.screenPadding,
    );
    expect(
      tester.widget<Text>(find.text('列表作品')).style?.fontSize,
      ShelfTokens.titleList,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('列表编辑态在封面左侧显示 22dp 多选框', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              BookshelfListCard(
                item: _item('列表作品'),
                editing: true,
                selected: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check), findsOneWidget);
    // 16dp 行内边距 + 22dp 多选框 + 12dp 间距。
    final cover = tester.getRect(find.byKey(const Key('bookshelf-cover')));
    expect(
      cover.left - tester.getRect(find.byType(BookshelfListCard)).left,
      ShelfTokens.screenPadding + 22 + ShelfTokens.spaceM,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('列表行有进度时渲染 3dp 进度条，无进度时不存在', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              BookshelfListCard(
                item: _item('有进度'),
                progress: 0.35,
                progressText: '第12章 · 35%',
                onTap: () {},
              ),
              BookshelfListCard(item: _item('无进度'), onTap: () {}),
            ],
          ),
        ),
      ),
    );

    final bar = find.byKey(const Key('shelf-list-progress'));
    expect(bar, findsOneWidget);
    expect(tester.getSize(bar).height, ShelfTokens.listProgressHeight);
    // 进度条属于第一行（「有进度」），不影响第二行。
    expect(
      tester.getTopLeft(bar).dy,
      lessThan(tester.getTopLeft(find.text('无进度')).dy),
    );
    expect(tester.takeException(), isNull);

    // 无进度值的卡不渲染进度条。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [BookshelfListCard(item: _item('无进度'), onTap: () {})],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('shelf-list-progress')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('双列整卡无重叠：封面满宽（减 padding）、比例 1.4、信息块在封面下方', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 162,
              height: 620,
              child: BookshelfDoubleCard(
                item: _item('双列作品'),
                badgeText: '35%',
                subtitleText: '测试作者',
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    final card = find.byKey(const Key('shelf-double-card'));
    expect(card, findsOneWidget);
    final cellWidth = tester.getSize(card).width;
    final coverRect = tester.getRect(find.byKey(const Key('bookshelf-cover')));
    // 封面 = 满格宽减卡片两侧 padding。
    expect(
      coverRect.width,
      closeTo(cellWidth - ShelfTokens.doubleCardPadding * 2, 0.01),
    );
    expect(
      coverRect.height / coverRect.width,
      closeTo(ShelfTokens.doubleCoverRatio, 0.01),
    );
    // 顺排布局（取消官方 84dp 重叠栈）：标题顶边必须不高于封面底边。
    expect(
      tester.getTopLeft(find.text('双列作品')).dy,
      greaterThanOrEqualTo(coverRect.bottom),
    );
    // 类型标签来自真实 kind 数据。
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('35%'), findsOneWidget);
    expect(find.text('测试作者'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('三种版式在无障碍大字号下都不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) => GridView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: ShelfTokens.screenPadding,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: ShelfTokens.gridColumns,
                  crossAxisSpacing: ShelfTokens.gridSpacing,
                  mainAxisSpacing: ShelfTokens.gridRunSpacing,
                  childAspectRatio: shelfGridChildAspectRatio(
                    context,
                    availableWidth: constraints.maxWidth,
                  ),
                ),
                itemCount: 6,
                itemBuilder: (_, index) => BookshelfGridCard(
                  item: _item('很长的书名用于验证无障碍字体排版$index'),
                  badgeText: '35%',
                  infoText: '第12章 · 35%',
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) => GridView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: ShelfTokens.screenPadding,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: ShelfTokens.gridSpacing,
                  childAspectRatio: shelfDoubleChildAspectRatio(
                    context,
                    availableWidth: constraints.maxWidth,
                  ),
                ),
                itemCount: 4,
                itemBuilder: (_, index) => BookshelfDoubleCard(
                  item: _item('很长很长的书名用于验证双列排版$index'),
                  subtitleText: '测试作者',
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: Scaffold(
            body: ListView(
              children: [
                for (var index = 0; index < 4; index++)
                  BookshelfListCard(
                    item: _item('很长的列表书名$index'),
                    progressText: '第12章 · 35%',
                    metaText: '测试作者',
                    onTap: () {},
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}

MediaItem _item(String title, {String kind = 'book'}) => MediaItem(
  id: title,
  title: title,
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '120',
  kind: kind,
);
