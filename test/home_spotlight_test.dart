import 'dart:ui' show ImageByteFormat, SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/ambient_backdrop.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_spotlight.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';

void main() {
  test('吸顶条的暖光按整页宽度推圆，再减掉居中的内容列左边距', () {
    // 手机：吸顶条就是整页宽，几何必须和改动前完全一致。
    final phone = homePinnedWash(viewportWidth: 393, barWidth: 393, top: 40);
    expect(phone.radius, homeWashRadius(393));
    expect(phone.center, homeWashCenter(393) - const Offset(0, 40));

    // 平板横屏 / 桌面：1024 的页面里内容列 840 居中，左右各留 92。圆心
    // 换算回页面坐标后必须和背景层重合，否则吸顶边上会错开一条淡横线。
    final tablet = homePinnedWash(viewportWidth: 1024, barWidth: 840, top: 24);
    expect(tablet.radius, homeWashRadius(1024));
    expect(tablet.center.dx, homeWashCenter(1024).dx - 92);
    expect(tablet.center.dx + 92, homeWashCenter(1024).dx);
    expect(tablet.center.dy, homeWashCenter(1024).dy - 24);
    // 半径也同源：按吸顶条自己的宽度算会小 18%，接缝处色阶对不上。
    expect(tablet.radius, isNot(homeWashRadius(840)));

    // 页面宽度未知（0）时退回吸顶条自己的宽度，即旧行为。
    final unknown = homePinnedWash(viewportWidth: 0, barWidth: 840, top: 24);
    expect(unknown.center, homeWashCenter(840) - const Offset(0, 24));
    expect(unknown.radius, homeWashRadius(840));
  });

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

  testWidgets('the selected category keeps room for its glow', (tester) async {
    await tester.pumpWidget(
      _app(
        CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              delegate: HomeTabBarDelegate(selectedIndex: 0, onSelect: (_) {}),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.getSize(find.byType(ListView));
    final chip = tester.getSize(find.byKey(const ValueKey('home_category_0')));
    // 胶囊 38 高居中在 54 高的视口里，上下各留 8px 给红色光晕。
    expect(list.height, 54);
    expect(chip.height, 38);
    expect(list.height - chip.height, greaterThanOrEqualTo(16));
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
          key: ValueKey(brightness),
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 600)),
            SliverPersistentHeader(
              pinned: true,
              delegate: HomeTabBarDelegate(
                selectedIndex: 0,
                onSelect: select,
                dark: brightness == Brightness.dark,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 2000)),
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
      final decoration = box.decoration as BoxDecoration;
      return decoration.color!;
    }

    Future<void> check(Brightness brightness) async {
      await tester.pumpWidget(app(brightness));
      await tester.pumpAndSettle();
      // 停在顶部时透明：首页顶部的暖光要能从频道条里穿过去。
      expect(canvasOf(), Colors.transparent);
      // 吸顶后要挡住下面滚过的卡片，换成当前画布色。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(canvasOf(), HomePalette(brightness == Brightness.dark).canvas);
    }

    await check(Brightness.light);
    await check(Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pinned tab bar carries the page wash across its top edge', (
    tester,
  ) async {
    // 吸顶条铺满画布后，它的顶边（状态栏下沿）会跟上面那截暖光断开。
    // 两种外观都要把同一段暖光接下去，不能出现一条硬横边。
    //
    // 状态栏故意取 120：吸顶条拿错这段高度时，暖光会整体错位 120px，
    // 像素差才明显到能坐实这个回归（真机上 40 的错位只有 1/255 量级）。
    const topInset = 120.0;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: topInset);
    addTearDown(tester.view.reset);

    final controller = ScrollController();
    addTearDown(controller.dispose);
    final boundary = GlobalKey();

    Future<Color> pixel(Offset fraction) async {
      final color = await tester.runAsync(() async {
        final object =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await object.toImage();
        final data = await image.toByteData(format: ImageByteFormat.rawRgba);
        final x = (fraction.dx * (image.width - 1)).round();
        final y = (fraction.dy * (image.height - 1)).round();
        final bytes = data!.buffer.asUint8List();
        final offset = (y * image.width + x) * 4;
        final pixel = Color.fromARGB(
          bytes[offset + 3],
          bytes[offset],
          bytes[offset + 1],
          bytes[offset + 2],
        );
        image.dispose();
        return pixel;
      });
      return color!;
    }

    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(brightness: brightness),
          home: RepaintBoundary(
            key: boundary,
            child: Builder(
              builder: (context) => Scaffold(
                backgroundColor: HomePalette.of(context).canvas,
                body: Stack(
                  children: [
                    Positioned.fill(child: AmbientBackdrop(scroll: controller)),
                    SafeArea(
                      bottom: false,
                      child: CustomScrollView(
                        controller: controller,
                        slivers: [
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 300),
                          ),
                          SliverPersistentHeader(
                            pinned: true,
                            delegate: HomeTabBarDelegate(
                              selectedIndex: 0,
                              onSelect: (_) {},
                              dark: brightness == Brightness.dark,
                              scroll: controller,
                              topInset: topInset,
                            ),
                          ),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 2000),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await tester.pumpAndSettle();

      // 吸顶条顶边落在 y=topInset，两侧各取一个像素：跨过边界不该有台阶。
      // 阈值卡在 1/255 量级；topInset 对不上时这里会差出 10/255 以上。
      final above = await pixel(const Offset(0.95, (topInset - 1) / 800));
      final below = await pixel(const Offset(0.95, (topInset + 3) / 800));
      expect((above.r - below.r).abs(), lessThan(0.01), reason: '$brightness');
      expect((above.g - below.g).abs(), lessThan(0.01), reason: '$brightness');
    }
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
