import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/bookshelf_card.dart';

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

  testWidgets('宫格封面按官方 1.3947369 比例并带圆角与角标', (tester) async {
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
    expect(cover.height, closeTo(200 * bookshelfGridCoverRatio, 0.01));
    // 圆角 12dp。
    final clip = tester.widget<ClipRRect>(
      find
          .descendant(
            of: find.byKey(const Key('bookshelf-cover')),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(clip.borderRadius, BorderRadius.circular(12));
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
              height: 320,
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

  testWidgets('列表条目是 110dp 行高加 60×90 封面', (tester) async {
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
      bookshelfListRowHeight,
    );
    final cover = tester.getSize(find.byKey(const Key('bookshelf-cover')));
    expect(cover.width, bookshelfListCoverWidth);
    expect(cover.height, bookshelfListCoverHeight);
    // 封面 marginStart 20dp。
    final card = tester.getRect(find.byType(BookshelfListCard));
    expect(
      tester.getRect(find.byKey(const Key('bookshelf-cover'))).left - card.left,
      bookshelfListSidePadding,
    );
    expect(
      tester.widget<Text>(find.text('列表作品')).style?.fontSize,
      15,
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
    // 20dp 外边距 + 22dp 多选框 + 20dp marginEnd。
    final cover = tester.getRect(find.byKey(const Key('bookshelf-cover')));
    expect(
      cover.left - tester.getRect(find.byType(BookshelfListCard)).left,
      bookshelfListSidePadding + 22 + 20,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('双列条目使用 110×162 封面并保留信息槽位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 162,
              height: 500,
              child: BookshelfDoubleCard(
                item: _item('双列作品'),
                badgeText: '35%',
                subtitleText: '测试作者',
                infoLines: const ['第12章 · 35%', '共 120章'],
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    final cover = tester.getSize(find.byKey(const Key('bookshelf-cover')));
    expect(cover.width, bookshelfDoubleCoverWidth);
    expect(cover.height, bookshelfDoubleCoverHeight);
    expect(
      tester.getRect(find.byKey(const Key('bookshelf-cover'))).left -
          tester.getRect(find.byType(BookshelfDoubleCard)).left,
      12,
    );
    expect(tester.widget<Text>(find.text('双列作品')).style?.fontSize, 16);
    expect(find.text('第12章 · 35%'), findsOneWidget);
    expect(find.text('共 120章'), findsOneWidget);
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
                padding: const EdgeInsets.symmetric(horizontal: 20),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: bookshelfGridColumns,
                  crossAxisSpacing: bookshelfGridSpacing,
                  mainAxisSpacing: bookshelfGridRunSpacing,
                  childAspectRatio: bookshelfGridChildAspectRatio(
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
                  horizontal: bookshelfDoubleSidePadding,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: bookshelfDoubleSpacing,
                  mainAxisSpacing: bookshelfDoubleRunSpacing,
                  childAspectRatio: bookshelfDoubleChildAspectRatio(
                    context,
                    availableWidth: constraints.maxWidth,
                  ),
                ),
                itemCount: 4,
                itemBuilder: (_, index) => BookshelfDoubleCard(
                  item: _item('很长很长的书名用于验证双列排版$index'),
                  subtitleText: '测试作者',
                  infoLines: const ['第12章 · 35%', '测试作者', '共 120章'],
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
