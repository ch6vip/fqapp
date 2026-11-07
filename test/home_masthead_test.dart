import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_archive.dart';
import 'package:fqapp/widgets/home/home_masthead.dart';

/// 顶栏：店名 + 档案编号 + 搜索 / 分类两个圆形入口。
///
/// 2026-11 重做后不再有搜索胶囊和热搜轮换，热搜词留在搜索页；这里钉住
/// 身份文案、两个入口的回调与占位、以及窄屏大字号不溢出。
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(400, 200),
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    );
  }

  testWidgets('shows the store name and its archive code', (tester) async {
    await pump(tester, HomeMasthead(onSearch: () {}));

    expect(find.text(HomeMasthead.brand), findsOneWidget);
    expect(find.text(HomeMasthead.brandCode), findsOneWidget);
  });

  testWidgets('search entry reports taps', (tester) async {
    var taps = 0;
    await pump(tester, HomeMasthead(onSearch: () => taps++));

    await tester.tap(find.byKey(const Key('home_search_button')));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('category entry sits right of search and reports taps', (
    tester,
  ) async {
    var taps = 0;
    await pump(tester, HomeMasthead(onSearch: () {}, onCategory: () => taps++));

    expect(
      tester.getCenter(find.byKey(const Key('home_category_button'))).dx,
      greaterThan(
        tester.getCenter(find.byKey(const Key('home_search_button'))).dx,
      ),
    );
    await tester.tap(find.byKey(const Key('home_category_button')));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('takes no space without a category callback', (tester) async {
    await pump(tester, HomeMasthead(onSearch: () {}));

    expect(find.byKey(const Key('home_category_button')), findsNothing);
  });

  testWidgets('fits a 320dp screen at 1.8x text', (tester) async {
    await pump(
      tester,
      HomeMasthead(onSearch: () {}, onCategory: () {}),
      size: const Size(320, 200),
      textScale: 1.8,
    );

    expect(find.text(HomeMasthead.brand), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('file codes use the kind prefix and the last five digits', () {
    MediaItem book(String id, {String kind = 'book'}) => MediaItem(
      id: id,
      title: 't',
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: kind,
    );

    expect(homeFileCode(book('7123456')), 'NOV-23456');
    expect(homeFileCode(book('42')), 'NOV-00042');
    expect(homeFileCode(book('x9001y', kind: 'video')), 'VID-09001');
    expect(homeFileCode(book('88', kind: 'audio')), 'AUD-00088');
  });
}
