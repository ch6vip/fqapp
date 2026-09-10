import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/bookshelf_card.dart';

void main() {
  testWidgets('a saved manju uses episode counts in shelf rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookshelfListCard(
            item: _item('测试漫剧', kind: 'manju'),
            compact: false,
            onTap: () {},
          ),
        ),
      ),
    );
    expect(find.text('共 120集'), findsOneWidget);
    expect(find.text('共 120章'), findsNothing);
  });

  testWidgets('narrow shelf rows fit large text and complete date labels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: Scaffold(
            body: ListView(
              children: [
                for (final compact in [false, true])
                  BookshelfListCard(
                    item: _item('测试作品'),
                    compact: compact,
                    readingText: '第12章 · 35%',
                    lastUpdateText: '12月31日',
                    badgeText: '100%',
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

  testWidgets('large badges stay inside narrow grid covers', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 70,
                height: 220,
                child: BookshelfGridCard(item: _item('书名'), onTap: () {}),
              ),
            ),
          ),
        ),
      ),
    );
    final cover = tester.getRect(find.byType(AspectRatio));
    final badge = tester.getRect(find.text('小说'));
    expect(badge.left, greaterThanOrEqualTo(cover.left));
    expect(badge.right, lessThanOrEqualTo(cover.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('grid shelf card uses a 3:4 cover and centered title', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 130,
              height: 225,
              child: BookshelfGridCard(item: _item('无封面作品'), onTap: () {}),
            ),
          ),
        ),
      ),
    );

    final cover = tester.widget<AspectRatio>(find.byType(AspectRatio).first);
    expect(cover.aspectRatio, bookshelfCoverAspectRatio);
    // Legado-style missing covers render the name on the generated cover and
    // once more as the regular grid caption.
    expect(find.text('无封面作品'), findsNWidgets(2));
    final titles = tester
        .widgetList<Text>(find.text('无封面作品'))
        .toList(growable: false);
    expect(
      titles.every((title) => title.textAlign == TextAlign.center),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('standard and compact shelf rows keep the same cover ratio', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              BookshelfListCard(
                item: _item('标准列表作品'),
                compact: false,
                readingText: '第12章 · 35%',
                lastUpdateText: '2小时前',
                badgeText: '35%',
                onTap: () {},
              ),
              BookshelfListCard(
                item: _item('紧凑列表作品'),
                compact: true,
                readingText: '第3章 · 10%',
                lastUpdateText: '刚刚',
                badgeText: '10%',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final covers = tester.widgetList<AspectRatio>(find.byType(AspectRatio));
    expect(covers, hasLength(2));
    expect(
      covers.every((cover) => cover.aspectRatio == bookshelfCoverAspectRatio),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('grid height adapts to accessibility text scaling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
          child: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) => GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: bookshelfGridChildAspectRatio(
                    context,
                    availableWidth: constraints.maxWidth,
                    columns: 3,
                  ),
                ),
                itemCount: 6,
                itemBuilder: (_, index) => BookshelfGridCard(
                  item: _item('很长的书名用于验证无障碍字体排版$index'),
                  onTap: () {},
                ),
              ),
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
