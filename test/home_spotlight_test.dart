import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_hero.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_spotlight.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';

void main() {
  testWidgets('swiping and next open the visible recommendation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        HomeSpotlight(
          items: [_item('one'), _item('two'), _item('three')],
          onOpen: (item) => opened.add(item.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('01 / 03'), findsOneWidget);

    await tester.fling(
      find.byKey(const Key('home_spotlight_pages')),
      const Offset(-320, 0),
      600,
    );
    await tester.pumpAndSettle();
    expect(find.text('02 / 03'), findsOneWidget);
    await tester.tap(find.text('故事 two').hitTestable());
    await tester.pumpAndSettle();
    expect(opened, ['two']);

    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pumpAndSettle();
    expect(find.text('03 / 03'), findsOneWidget);
    await tester.tap(find.text('故事 three').hitTestable());
    await tester.pumpAndSettle();
    expect(opened, ['two', 'three']);

    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pumpAndSettle();
    expect(find.text('01 / 03'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refreshing a shorter set resets to its first story', (
    tester,
  ) async {
    final opened = <String>[];
    Widget content(List<MediaItem> items) => _app(
      HomeSpotlight(items: items, onOpen: (item) => opened.add(item.id)),
    );
    await tester.pumpWidget(
      content([_item('one'), _item('two'), _item('three')]),
    );
    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(content([_item('fresh')]));
    await tester.pumpAndSettle();
    expect(find.text('01 / 01'), findsOneWidget);
    expect(find.byKey(const Key('home_spotlight_next')), findsNothing);
    await tester.tap(find.text('故事 fresh'));
    await tester.pumpAndSettle();
    expect(opened, ['fresh']);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (width: 320.0, scale: 1.0, dark: false),
    (width: 320.0, scale: 1.8, dark: true),
    (width: 320.0, scale: 3.0, dark: false),
    (width: 800.0, scale: 1.0, dark: true),
  ]) {
    testWidgets('story content remains readable with $scenario', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(scenario.width, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final item = _item(
        'long',
        title: '一本名字很长但也要保持清晰易读的故事',
        author: '作者名字很长也不会挤出卡片边界',
        ep: '更新至一千零一章',
      );
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: HomeSpotlight(items: [item, _item('next')], onOpen: (_) {}),
          ),
          scale: scenario.scale,
          dark: scenario.dark,
          reducedMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        _app(
          LayoutBuilder(
            builder: (context, constraints) => GridView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              gridDelegate: homeGridDelegate(
                context,
                constraints.maxWidth - 40,
              ),
              children: List.generate(
                6,
                (_) => HomeMediaCard(item: item, onTap: () {}),
              ),
            ),
          ),
          scale: scenario.scale,
          dark: scenario.dark,
          reducedMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a category can be selected through its semantics action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    int? selected;
    await tester.pumpWidget(
      _app(
        CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              delegate: HomeTabBarDelegate(
                selectedIndex: 0,
                onSelect: (index) => selected = index,
              ),
            ),
          ],
        ),
      ),
    );
    final node = tester.getSemantics(
      find.byKey(const ValueKey('home_category_1')),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(selected, 1);
    semantics.dispose();
  });

  testWidgets('the pinned strip keeps the same gutter as the search row', (
    tester,
  ) async {
    // 官方 `alx.xml` 的内边距是 paddingStart 20dp / paddingEnd 13dp，天生
    // 不对称：条带滚到头，「推荐」左边比末位 tab 右边多 7dp，看着就是没跟
    // 它正上方的搜索框对齐（用户 2026-10-25 指出）。两侧都收成 16dp，与
    // HomeHero 同一对栏距。
    //
    // 只收 padding 还不够：六个分类在手机宽上放得下，右边空出来的其实是剩余
    // 空间，所以间隔还得把富余摊掉，末位 tab 才会贴到同一条竖线上。
    await tester.binding.setSurfaceSize(const Size(360, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    void ignore(int _) {}
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            HomeHero(onSearch: () {}),
            CustomScrollView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  delegate: HomeTabBarDelegate(
                    selectedIndex: 0,
                    onSelect: ignore,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final search = tester.getRect(find.byKey(const Key('home_search_button')));
    final firstTab = find.byKey(const ValueKey('home_category_0'));
    expect(
      tester
          .widget<SingleChildScrollView>(
            find
                .ancestor(
                  of: firstTab,
                  matching: find.byType(SingleChildScrollView),
                )
                .first,
          )
          .padding,
      const EdgeInsets.symmetric(horizontal: HomeTabBarDelegate.sidePadding),
    );
    // 左端：与搜索框同一条竖线。
    expect(tester.getRect(firstTab).left, search.left);

    // 右端：与左端同宽，不再少掉那一段剩余空间。
    final lastIndex = homeCategories.length - 1;
    final secondTab = tester.getRect(
      find.byKey(const ValueKey('home_category_1')),
    );
    final last = tester.getRect(
      find.byKey(ValueKey('home_category_$lastIndex')),
    );
    expect(last.right, closeTo(360 - HomeTabBarDelegate.sidePadding, 0.01));
    // 富余确实摊到了间隔上，而不是靠 padding 硬塞。
    expect(
      secondTab.left - tester.getRect(firstTab).right,
      greaterThan(HomeTabBarDelegate.tabSpacing),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide window stops spreading the tabs', (tester) async {
    // 桌面窗口能宽到六个数倍：富余无上限地摊到间隔上会把分类扯到整屏两端，
    // 比留白更难看，所以封顶在 tabSpacing + maxExtraSpacing。
    await tester.binding.setSurfaceSize(const Size(900, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    void ignore(int _) {}
    await tester.pumpWidget(
      _app(
        CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              delegate: HomeTabBarDelegate(selectedIndex: 0, onSelect: ignore),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = tester.getRect(find.byKey(const ValueKey('home_category_0')));
    final second = tester.getRect(find.byKey(const ValueKey('home_category_1')));
    expect(
      second.left - first.right,
      closeTo(
        HomeTabBarDelegate.tabSpacing + HomeTabBarDelegate.maxExtraSpacing,
        0.01,
      ),
    );
    expect(first.left, HomeTabBarDelegate.sidePadding);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an overflowing strip scrolls to the same gutters', (
    tester,
  ) async {
    // 服务端下发的分类比本地六个多，360 宽放不下：两端内边距这时才直接可见。
    await tester.binding.setSurfaceSize(const Size(360, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    void ignore(int _) {}
    const categories = [
      HomeCategory('推荐', Icons.circle),
      HomeCategory('小说', Icons.circle),
      HomeCategory('短剧', Icons.circle),
      HomeCategory('漫剧', Icons.circle),
      HomeCategory('漫画', Icons.circle),
      HomeCategory('听书', Icons.circle),
      HomeCategory('精选', Icons.circle),
      HomeCategory('完本', Icons.circle),
    ];
    await tester.pumpWidget(
      _app(
        CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              delegate: HomeTabBarDelegate(
                selectedIndex: 0,
                onSelect: ignore,
                categories: categories,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final firstTab = find.byKey(const ValueKey('home_category_0'));
    expect(tester.getRect(firstTab).left, HomeTabBarDelegate.sidePadding);

    await tester.fling(firstTab, const Offset(-400, 0), 900);
    await tester.pumpAndSettle();
    final lastIndex = categories.length - 1;
    final last = tester.getRect(
      find.byKey(ValueKey('home_category_$lastIndex')),
    );
    expect(last.right, lessThanOrEqualTo(360));
    expect(360 - last.right, closeTo(HomeTabBarDelegate.sidePadding, 0.01));
    expect(tester.takeException(), isNull);
  });

  test('the pinned tab bar rebuilds when the palette changes', () {
    void ignore(int _) {}
    final light = HomeTabBarDelegate(
      selectedIndex: 0,
      onSelect: ignore,
      dark: false,
    );
    final dark = HomeTabBarDelegate(
      selectedIndex: 0,
      onSelect: ignore,
      dark: true,
    );
    expect(dark.shouldRebuild(light), isTrue);
    expect(
      light.shouldRebuild(
        HomeTabBarDelegate(selectedIndex: 0, onSelect: ignore),
      ),
      isFalse,
    );

    // OLED 只在深色下生效，墨水屏本身也是浅色外观：两者都不翻 dark，
    // 漏进 shouldRebuild 的话切完仍画旧画布，吸顶处会露出一条色差。
    expect(
      HomeTabBarDelegate(
        selectedIndex: 0,
        onSelect: ignore,
        dark: true,
        oled: true,
      ).shouldRebuild(dark),
      isTrue,
    );
    expect(
      HomeTabBarDelegate(
        selectedIndex: 0,
        onSelect: ignore,
        eink: true,
      ).shouldRebuild(light),
      isTrue,
    );
  });

  testWidgets('the pinned tab bar follows the theme without changing tabs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    void select(int _) {}
    Widget app(Brightness brightness) {
      return MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: HomeTabBarDelegate(
                selectedIndex: 0,
                onSelect: select,
                dark: brightness == Brightness.dark,
              ),
            ),
          ],
        ),
      );
    }

    Color canvasOf() {
      final box = tester
          .widgetList<DecoratedBox>(
            find.ancestor(
              of: find.byKey(const ValueKey('home_category_0')),
              matching: find.byType(DecoratedBox),
            ),
          )
          .first;
      return (box.decoration as BoxDecoration).color!;
    }

    await tester.pumpWidget(app(Brightness.light));
    await tester.pumpAndSettle();
    expect(canvasOf(), const HomePalette(false).canvas);

    await tester.pumpWidget(app(Brightness.dark));
    await tester.pumpAndSettle();
    expect(canvasOf(), const HomePalette(true).canvas);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion leaves press and page changes settled', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            HomePressable(
              onTap: () => taps++,
              child: const SizedBox(width: 100, height: 50, child: Text('打开')),
            ),
            HomeSpotlight(items: [_item('one'), _item('two')], onOpen: (_) {}),
          ],
        ),
        reducedMotion: true,
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    expect(taps, 1);
    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pump();
    await tester.pump();
    expect(find.text('02 / 02'), findsOneWidget);
    // Standard Material ink feedback may finish its opacity transition;
    // the carousel itself must already be on the next page after one frame.
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(
  Widget child, {
  double scale = 1,
  bool dark = false,
  bool reducedMotion = false,
}) => MaterialApp(
  theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: reducedMotion,
    ),
    child: child!,
  ),
  home: Scaffold(body: child),
);

MediaItem _item(
  String id, {
  String? title,
  String author = '',
  String ep = '',
}) => MediaItem(
  id: id,
  title: title ?? '故事 $id',
  cover: '',
  author: author,
  badge: '',
  ep: ep,
  kind: 'book',
);
