import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_hero.dart';
import 'package:fqapp/widgets/home/home_skeleton.dart';

void main() {
  testWidgets(
    'manju, manga and audio tabs show the matching feed after insertion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      MediaItem item(String label) => MediaItem(
        id: label,
        title: '$label 作品',
        cover: '',
        author: '',
        badge: '',
        ep: '',
        kind: HomeNotifier.tabKinds[label]!,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeProvider.overrideWith(
              () => HomeNotifier(
                homepageLoader:
                    ({
                      int tabType = 2,
                      int offset = 0,
                      String? sessionId,
                    }) async => HomepagePage(
                      items: [
                        item(
                          HomeNotifier.tabTypes.entries
                              .firstWhere((entry) => entry.value == tabType)
                              .key,
                        ),
                      ],
                      nextOffset: null,
                      sessionId: null,
                    ),
                searchLoader: (query, {int page = 1}) async => [
                  SearchTab(title: query, items: [item(query)], hasMore: false),
                ],
              ),
            ),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['漫剧', '漫画', '听书']) {
        final index = HomeNotifier.tabs.indexOf(label);
        final tab = find.byKey(ValueKey('home_category_$index'));
        await tester.ensureVisible(tab);
        await tester.pumpAndSettle();
        await tester.tap(tab);
        await tester.pumpAndSettle();
        expect(find.text('$label 作品'), findsOneWidget);
        if (label == '漫剧') expect(find.text('观看漫剧'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('外部 ScrollController 能驱动首页回顶部（底部栏重复点击的依据）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    // 壳层持有控制器：官方「重复点底部首页 tab 回顶部」发生在底部栏，
    // 不在页内，所以首页必须能把控制器交出去（issue：首页回顶部）。
    final controller = ScrollController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: [
                      for (var i = 0; i < 40; i++)
                        MediaItem(
                          id: 'i$i',
                          title: '作品 $i',
                          cover: '',
                          author: '',
                          badge: '',
                          ep: '',
                          kind: 'book',
                        ),
                    ],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => [],
            ),
          ),
        ],
        child: MaterialApp(home: HomePage(scrollController: controller)),
      ),
    );
    await tester.pumpAndSettle();

    final feed = find.byKey(const Key('home_feed'));
    await tester.drag(feed, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(controller.position.pixels, greaterThan(0));

    // 壳层就是这样回顶部的（官方 scrollToPosition(0) 的等价动作）。
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    expect(controller.position.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页按上游区块渲染：排行榜条 + 猜你喜欢网格', (tester) async {
    // 视口要高：排行榜区块在猜你喜欢上面，矮屏会把后面的区块挤出视口，
    // find 默认只看可见节点。
    await tester.binding.setSurfaceSize(const Size(400, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    MediaItem book(String id, String title) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: [
                      book('r1', '榜单书一'),
                      book('r2', '榜单书二'),
                      book('c1', '猜你喜欢一'),
                      book('c2', '猜你喜欢二'),
                    ],
                    cells: [
                      HomeCell(
                        showType: 511,
                        name: '排行榜',
                        id: '',
                        style: const {},
                        items: const [],
                        children: [
                          HomeCell(
                            showType: 512,
                            name: '',
                            id: '',
                            style: const {},
                            items: [book('r1', '榜单书一')],
                            children: const [],
                          ),
                          HomeCell(
                            showType: 512,
                            name: '',
                            id: '',
                            style: const {},
                            items: [book('r2', '榜单书二')],
                            children: const [],
                          ),
                        ],
                      ),
                      HomeCell(
                        showType: 384,
                        name: '猜你喜欢',
                        id: '',
                        style: const {},
                        items: const [],
                        children: [
                          HomeCell(
                            showType: 385,
                            name: '',
                            id: '',
                            style: const {},
                            items: [book('c1', '猜你喜欢一'), book('c2', '猜你喜欢二')],
                            children: const [],
                          ),
                        ],
                      ),
                    ],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    // 排行榜标题在；卡片流的标题按 m0.java case 82 强制隐藏。
    expect(find.text('排行榜'), findsWidgets);
    expect(find.text('猜你喜欢'), findsNothing);
    // 排行榜预览：序号 1、2 都渲染出来（官方 b7d.xml 的序号列）。
    expect(find.text('1'), findsWidgets);
    expect(find.text('2'), findsWidgets);
    // 卡片都在（榜单书 + 书卡流，流无标题、无话题卡）。
    expect(find.text('榜单书一'), findsWidgets);
    expect(find.text('猜你喜欢一'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非「推荐」分类也按自己的区块渲染', (tester) async {
    // 官方 m0 对每个 tab_type 一视同仁地建区块，所以「经典」「漫画」这些
    // 分类同样渲染自己那份 cell_data，而不是退回旧的「今日焦点 + 值得一看」
    // 管线。
    await tester.binding.setSurfaceSize(const Size(400, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    MediaItem book(String id, String title) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: [book('c1', '经典书一'), book('c2', '经典书二')],
                    cells: [
                      HomeCell(
                        showType: 384,
                        name: '经典必读',
                        id: '',
                        style: const {},
                        items: const [],
                        children: [
                          HomeCell(
                            showType: 385,
                            name: '',
                            id: '',
                            style: const {},
                            items: [book('c1', '经典书一'), book('c2', '经典书二')],
                            children: const [],
                          ),
                        ],
                      ),
                    ],
                    tabs: const [
                      HomeTabItem(type: 2, title: '推荐'),
                      HomeTabItem(type: 11, title: '经典'),
                    ],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    // 先切到「经典」（服务端下标 1）。
    await tester.tap(find.byKey(const ValueKey('home_category_1')));
    await tester.pumpAndSettle();

    // 无限流（384/385）不渲染自己的标题，只有卡片。
    expect(find.text('经典必读'), findsNothing);
    expect(find.text('经典书一'), findsWidgets);
    // 旧管线的东西不该出现。
    expect(find.text('值得一看'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('推荐 tab 书卡流照常渲染：无标题、无话题卡', (tester) async {
    // 书荒广场话题卡已在解析层删除；流的标题按 m0.java case 82 强制隐
    // 藏。卡片本身照常渲染。
    await tester.binding.setSurfaceSize(const Size(400, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    MediaItem book(String id, String title) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: [book('c1', '猜你喜欢一'), book('c2', '猜你喜欢二')],
                    cells: [
                      HomeCell(
                        showType: 384,
                        name: '猜你喜欢',
                        id: '',
                        // 线上响应可能不带 hide_title——流类型必须无条件隐藏。
                        style: const {},
                        items: const [],
                        children: [
                          HomeCell(
                            showType: 385,
                            name: '',
                            id: '',
                            style: const {},
                            items: [book('c1', '猜你喜欢一'), book('c2', '猜你喜欢二')],
                            children: [],
                          ),
                        ],
                      ),
                    ],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    // 书卡都在，标题与话题卡不出现。
    expect(find.text('猜你喜欢一'), findsWidgets);
    expect(find.text('猜你喜欢二'), findsWidgets);
    expect(find.text('猜你喜欢'), findsNothing);
    expect(find.text('书荒广场'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 1.8]) {
    testWidgets('search hint fits a narrow phone at text scale $scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeProvider.overrideWith(
              () => HomeNotifier(
                homepageLoader:
                    ({
                      int tabType = 2,
                      int offset = 0,
                      String? sessionId,
                    }) async => HomepagePage(
                      items: [],
                      nextOffset: null,
                      sessionId: null,
                    ),
                searchLoader: (query, {int page = 1}) async => [],
              ),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const HomePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final hint = find.text(HomeHero.searchHint);
      expect(hint, findsOneWidget);
      // 官方顶栏搜索框右侧没有常驻按钮（`h4f`/`gpe` 均 gone，「识剧」入口
      // 也已删除），提示文案要能在窄屏上完整放下、不出溢出。
      expect(tester.getRect(hint).right, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a long homepage error can be scrolled to retry successfully', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final message = List.filled(60, '服务暂时不可用，请稍后重试。').join();
    var failing = true;
    var homepageRequests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    // Count the novel stream only: the combined feed also asks
                    // the manju stream (24) for its manju group, which is not
                    // what this retry assertion is about.
                    if (tabType == 2) homepageRequests++;
                    if (failing) throw ApiException(message);
                    return const HomepagePage(
                      items: [],
                      nextOffset: null,
                      sessionId: null,
                    );
                  },
              searchLoader: (query, {int page = 1}) async {
                if (failing) throw ApiException(message);
                return [];
              },
            ),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    expect(tester.takeException(), isNull);
    final scrollable = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(find.text('重试').hitTestable(), findsNothing);
    await tester.scrollUntilVisible(
      find.text('重试'),
      400,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('重试').hitTestable(), findsOneWidget);

    failing = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(homepageRequests, 2);
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text(message), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two initial empty pages continue loading until items appear', (
    tester,
  ) async {
    final offsets = <int>[];
    final secondPage = Completer<HomepagePage>();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    // Manju has its own stream (24) in the combined feed; keep
                    // it out of this test's cursor tracking.
                    if (tabType != 2) {
                      return const HomepagePage(
                        items: [],
                        nextOffset: null,
                        sessionId: null,
                      );
                    }
                    offsets.add(offset);
                    if (offset == 1) return secondPage.future;
                    return HomepagePage(
                      items: [
                        if (offset == 2)
                          MediaItem(
                            id: 'later-book',
                            title: '后续小说',
                            cover: '',
                            author: '',
                            badge: '',
                            ep: '',
                            kind: 'book',
                          ),
                      ],
                      nextOffset: offset == 0 ? 1 : null,
                      sessionId: 'session',
                    );
                  },
              searchLoader: (query, {int page = 1}) async => [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(offsets, [0, 1]);
    // Cold first load paints the `cmc.xml` skeleton, not a spinner.
    expect(find.byType(HomeSkeleton), findsOneWidget);
    expect(find.text('暂无内容'), findsNothing);

    secondPage.complete(
      HomepagePage(items: [], nextOffset: 2, sessionId: 'session'),
    );
    await tester.pump();
    await tester.pump();
    expect(offsets, [0, 1]);
    expect(find.byType(HomeSkeleton), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(offsets, [0, 1, 2]);
    expect(find.text('后续小说'), findsOneWidget);
    expect(find.text('暂无内容'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short fast pages continue loading without a scroll event', (
    tester,
  ) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    // The combined feed also reads the manju stream (24) for its
                    // manju group; keep it empty so this test tracks the novel
                    // stream's cursor only.
                    if (tabType != 2) {
                      return const HomepagePage(
                        items: [],
                        nextOffset: null,
                        sessionId: null,
                      );
                    }
                    offsets.add(offset);
                    return HomepagePage(
                      items: [
                        MediaItem(
                          id: '$offset',
                          title: '小说 $offset',
                          cover: '',
                          author: '',
                          badge: '',
                          ep: '',
                          kind: 'book',
                        ),
                      ],
                      nextOffset: offset < 3 ? offset + 1 : null,
                      sessionId: 'session',
                    );
                  },
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
    for (var tick = 0; tick < 5; tick++) {
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }
    expect(offsets, [0, 1, 2, 3]);
    // The hero and featured card push the grid below the fold, so scroll the
    // feed until the lazily-built card enters the viewport. The tab strip is
    // a horizontal Scrollable too, so match the vertical feed by axis.
    final feedScrollable = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    await tester.scrollUntilVisible(
      find.text('小说 3'),
      300,
      scrollable: feedScrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('小说 3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('the home tab bar follows theme changes from HomePage', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final mode = ValueNotifier(ThemeMode.light);
    addTearDown(mode.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder: (context, themeMode, _) => ProviderScope(
          overrides: [
            homeProvider.overrideWith(
              () => HomeNotifier(
                homepageLoader:
                    ({
                      int tabType = 2,
                      int offset = 0,
                      String? sessionId,
                    }) async => HomepagePage(
                      items: [
                        MediaItem(
                          id: '1',
                          title: '小说 1',
                          cover: '',
                          author: '',
                          badge: '',
                          ep: '',
                          kind: 'book',
                        ),
                      ],
                      nextOffset: null,
                      sessionId: null,
                    ),
                searchLoader: (query, {int page = 1}) async => const [],
              ),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.light),
            darkTheme: ThemeData(brightness: Brightness.dark),
            themeMode: themeMode,
            home: const HomePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

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

    expect(canvasOf(), const HomePalette(false).canvas);
    mode.value = ThemeMode.dark;
    await tester.pumpAndSettle();
    expect(canvasOf(), const HomePalette(true).canvas);
    expect(tester.takeException(), isNull);
  });
}
