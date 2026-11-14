import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/home_feed_cache.dart';
import 'package:fqapp/widgets/home/classic_home_continue_row.dart';
import 'package:fqapp/widgets/home/classic_home_feed_states.dart';
import 'package:fqapp/widgets/home/classic_home_rank_rail.dart';
import 'package:fqapp/widgets/home/classic_home_skeleton.dart';
import 'package:fqapp/widgets/home/classic_home_stream_footer.dart';
import 'package:fqapp/widgets/home/classic_home_tab_bar.dart';
import 'package:fqapp/widgets/home/home_archive.dart';
import 'package:fqapp/widgets/home/home_cell_blocks.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_hero.dart';
import 'package:fqapp/widgets/home/home_masthead.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_rank_shelf.dart';
import 'package:fqapp/widgets/home/home_reading_row.dart';
import 'package:fqapp/widgets/home/home_shelf.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';
import 'package:fqapp/widgets/tab_swipe_area.dart';

MediaItem _book(int i, {String prefix = '榜书'}) => MediaItem(
  id: '$prefix-$i',
  title: '$prefix$i',
  cover: '',
  author: '作者$i',
  badge: '',
  ep: '',
  kind: 'book',
  rankTags: const ['9151万热度'],
);

HomeCell _rankCell() => HomeCell(
  showType: 511,
  name: '排行榜',
  id: 'rank-1',
  style: const {},
  items: [for (var i = 1; i <= 12; i++) _book(i)],
  children: const [],
  extra: const {
    'rank_with_category_data': {
      'rank_algo_list': [
        {'rank_algo': 101, 'rank_name': '推荐榜'},
        {'rank_algo': 100, 'rank_name': '完本榜'},
        {'rank_algo': 102, 'rank_name': '巅峰榜'},
      ],
    },
  },
);

ThemeData _theme(AppThemeStyle style) =>
    ThemeData(extensions: [AppStyleTokens.forStyle(style)]);

Widget _classic(Widget child) => MaterialApp(
  theme: _theme(AppThemeStyle.classic),
  home: Scaffold(body: child),
);

Widget _switchable(ValueNotifier<AppThemeStyle> style, Widget child) =>
    ValueListenableBuilder<AppThemeStyle>(
      valueListenable: style,
      child: child,
      builder: (context, value, child) => MaterialApp(
        theme: _theme(value),
        themeAnimationDuration: const Duration(milliseconds: 300),
        home: child,
      ),
    );

/// 选中态下划线的 Key（每个标签各一份，用祖先 InkWell 区分）。
const Key _indicatorKey = Key('rank_board_indicator');

/// 源码里指示条到文字的间距（_boardIndicatorGap）。
const double _expectedIndicatorGap = 5;

/// 某个标签文字外围的 InkWell。重名榜名用 occurrence 区分先后。
Finder _boardInk(String name, {int occurrence = 0}) => find
    .ancestor(
      of: find.text(name).at(occurrence),
      matching: find.byType(InkWell),
    )
    .first;

/// 标签文字外围的 InkWell 矩形：48dp 最小热区盒。
Rect _boardWell(WidgetTester tester, String name, {int occurrence = 0}) =>
    tester.getRect(_boardInk(name, occurrence: occurrence));

/// 标签内部的下划线矩形（按 Key 定位，不依赖 Container 的唯一性）。
Rect _boardIndicator(WidgetTester tester, String name, {int occurrence = 0}) =>
    tester.getRect(
      find.descendant(
        of: _boardInk(name, occurrence: occurrence),
        matching: find.byKey(_indicatorKey),
      ),
    );

/// 标签内部的下划线 widget（用于断言选中态颜色）。
Container _boardIndicatorWidget(
  WidgetTester tester,
  String name, {
  int occurrence = 0,
}) => tester.widget<Container>(
  find.descendant(
    of: _boardInk(name, occurrence: occurrence),
    matching: find.byKey(_indicatorKey),
  ),
);

/// 「更多」的 48dp 热区矩形。
Rect _moreRect(WidgetTester tester) =>
    tester.getRect(find.byType(ClassicHomeBlockMore));

/// 「更多」热区内某个标签空隙的中心 x；找不到返回 null。
/// 重名榜名按出现顺序取对应标签，不会错位。
double? _gapInMoreHotspot(WidgetTester tester, List<String> names) {
  final more = _moreRect(tester);
  var previousRight = double.negativeInfinity;
  final seen = <String, int>{};
  for (final name in names) {
    final occurrence = seen[name] ?? 0;
    seen[name] = occurrence + 1;
    final well = _boardWell(tester, name, occurrence: occurrence);
    final candidate = (previousRight + well.left) / 2;
    if (previousRight.isFinite &&
        candidate > more.left &&
        candidate < more.right) {
      return candidate;
    }
    previousRight = well.right;
  }
  return null;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HomeFeedCache.hiveReady = false;
  });
  tearDown(() => HomeFeedCache.hiveReady = false);

  testWidgets(
    'old search capsules are 40 high, radius 20, with injected cues',
    (tester) async {
      var searches = 0;
      var categories = 0;
      var loads = 0;
      await tester.pumpWidget(
        _classic(
          HomeHero(
            onSearch: () => searches++,
            onCategory: () => categories++,
            cueLoader: () async {
              loads++;
              return const SearchCue(
                words: ['番茄四大封神小说', '下一条'],
                rotateIntervalMs: 1000,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.text('番茄四大封神小说'), findsOneWidget);
      for (final key in ['home_search_button', 'home_category_button']) {
        final capsule = find.byKey(Key(key));
        expect(tester.getSize(capsule).height, 40);
        final container = tester.widget<Container>(
          find.descendant(of: capsule, matching: find.byType(Container)).first,
        );
        expect(
          (container.decoration! as BoxDecoration).borderRadius,
          BorderRadius.circular(20),
        );
      }
      await tester.tap(find.byKey(const Key('home_search_button')));
      await tester.tap(find.byKey(const Key('home_category_button')));
      expect(searches, 1);
      expect(categories, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('下一条'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('null and failing cue loaders keep the offline search hint', (
    tester,
  ) async {
    for (final Future<SearchCue> Function()? loader in [
      null,
      () => throw StateError('sync offline'),
      () async => throw StateError('async offline'),
    ]) {
      await tester.pumpWidget(
        _classic(
          HomeHero(key: UniqueKey(), onSearch: () {}, cueLoader: loader),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(HomeHero.searchHint), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'classic category labels retain the old underline and selected typography',
    (tester) async {
      var selected = -1;
      await tester.pumpWidget(
        _classic(
          HomeTabBar(selectedIndex: 0, onSelect: (index) => selected = index),
        ),
      );
      expect(find.byType(ClassicHomeTabBar), findsOneWidget);
      final tab = find.byKey(const ValueKey('home_category_0'));
      final style = tester.widget<AnimatedDefaultTextStyle>(
        find.descendant(
          of: tab,
          matching: find.byType(AnimatedDefaultTextStyle),
        ),
      );
      expect(style.style.fontSize, 17);
      expect(style.style.fontWeight, FontWeight.w700);
      // The underline is drawn once for the whole bar now, so it can slide
      // between the categories; it keeps the old 16 × 2.5dp shape.
      final indicator = tester.widget<AnimatedPositioned>(
        find.byKey(const ValueKey('home_tab_indicator')),
      );
      expect(indicator.width, 16);
      expect(indicator.height, 2.5);
      await tester.tap(find.byKey(const ValueKey('home_category_1')));
      expect(selected, 1);
    },
  );

  testWidgets(
    'continue reading is one text row without a card, cover or progress bar',
    (tester) async {
      var opened = 0;
      var dismissed = 0;
      final style = ValueNotifier(AppThemeStyle.archive);
      addTearDown(style.dispose);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _switchable(
            style,
            Scaffold(
              body: HomeContinueRow(
                now: ReadingNow(
                  item: _book(1),
                  verb: '继续阅读',
                  detail: '读到 第3章',
                  progress: .4,
                ),
                onOpen: () => opened++,
                onDismiss: () => dismissed++,
              ),
            ),
          ),
        );
        expect(find.text('CONTINUE / 读到 第3章'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          .4,
        );
        style.value = AppThemeStyle.classic;
        await tester.pumpAndSettle();
        expect(find.byType(ClassicHomeContinueRow), findsOneWidget);
        expect(find.byType(StoryCover), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.byType(HomeCode), findsNothing);
        expect(
          find.descendant(
            of: find.byType(ClassicHomeContinueRow),
            matching: find.byType(Container),
          ),
          findsNothing,
        );
        expect(find.text('继续阅读'), findsOneWidget);
        expect(find.text('榜书1 · 读到 第3章'), findsOneWidget);
        expect(find.text('40%'), findsOneWidget);
        expect(tester.getSize(find.byType(ClassicHomeContinueRow)).height, 44);
        await tester.tap(find.text('榜书1 · 读到 第3章'));
        await tester.tap(find.bySemanticsLabel('隐藏继续阅读'));
        expect(opened, 1);
        expect(dismissed, 1);
        style.value = AppThemeStyle.archive;
        await tester.pumpAndSettle();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.text('CONTINUE / 读到 第3章'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'classic TOP covers are a multi-cover 100x140 rail; each opens on one tap',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final opened = <String>[];
      var more = 0;
      await tester.pumpWidget(
        _classic(
          HomeRankCell(
            cell: _rankCell(),
            onOpen: (item) => opened.add(item.id),
            onMore: () => more++,
          ),
        ),
      );
      expect(find.byType(HomeRankShelf), findsNothing);
      expect(find.byType(HomeSectionHeader), findsOneWidget);
      expect(find.byType(HomeSectionLabel), findsNothing);
      expect(find.byType(HomeCode), findsNothing);
      expect(find.text('完整榜单'), findsNothing);
      for (var i = 1; i <= 3; i++) {
        expect(find.text('TOP $i'), findsOneWidget);
        final card = find.byKey(ValueKey('rank:book:榜书-$i'));
        final cover = find.descendant(
          of: card,
          matching: find.byType(StoryCover),
        );
        expect(tester.getSize(cover), const Size(100, 140));
        final clip = tester.widget<ClipRRect>(
          find.descendant(of: card, matching: find.byType(ClipRRect)),
        );
        expect(clip.borderRadius, BorderRadius.circular(10));
        await tester.tap(find.text('TOP $i'));
        await tester.pumpAndSettle();
      }
      expect(opened, ['榜书-1', '榜书-2', '榜书-3']);
      expect(find.text('TOP 4'), findsNothing);
      final boardLabel = find.text('推荐榜');
      expect(tester.widget<Text>(boardLabel).style!.fontSize, 13);
      final boardColumn = find
          .ancestor(of: boardLabel, matching: find.byType(Column))
          .first;
      final underline = tester.widget<Container>(
        find.descendant(of: boardColumn, matching: find.byKey(_indicatorKey)),
      );
      expect(underline.constraints!.maxWidth, 16);
      expect(underline.constraints!.maxHeight, 2);
      // 48dp 热区：文字只占顶部约 39×15dp，四周留白也是可点区。覆盖
      // 方案（#384）里热区不参与行高，若被祖先裁剪或 sibling 遮挡，边缘
      // 两下会静默失效——只 tap 文字中心测不到这件事。
      final moreBox = tester.getRect(find.byType(ClassicHomeBlockMore));
      await tester.tapAt(Offset(moreBox.left + 2, moreBox.center.dy));
      expect(more, 1, reason: '文字左侧留白必须可点');
      await tester.tapAt(Offset(moreBox.center.dx, moreBox.bottom - 2));
      expect(more, 2, reason: '文字下方的热区必须可点');
      await tester.tap(find.text('更多'));
      expect(more, 3);
      await tester.drag(
        find.byKey(const Key('classic_home_rank_rail')),
        const Offset(-780, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('榜书9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'in-flight rank selection survives classic/archive switch without duplicate requests',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final style = ValueNotifier(AppThemeStyle.archive);
      addTearDown(style.dispose);
      final wasDegraded = HomeRankShelf.degraded;
      HomeRankShelf.degraded = false;
      addTearDown(() => HomeRankShelf.degraded = wasDegraded);
      final pending = Completer<List<MediaItem>>();
      final calls = <String>[];
      final cell = _rankCell();
      await tester.pumpWidget(
        _switchable(
          style,
          Scaffold(
            body: HomeRankCell(
              cell: cell,
              onOpen: (_) {},
              onMore: () {},
              loadBoard: (id, algo) {
                calls.add('$id/$algo');
                return pending.future;
              },
            ),
          ),
        ),
      );
      expect(find.byType(HomeRankShelf), findsOneWidget);
      expect(find.byKey(const Key('home_rank_flat_rail')), findsNothing);
      expect(find.text('01 / RANKING'), findsOneWidget);
      final cellState = tester.state(find.byType(HomeRankCell));
      await tester.tap(find.text('完本榜'));
      await tester.pump();
      expect(calls, ['rank-1/100']);
      style.value = AppThemeStyle.classic;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.state(find.byType(HomeRankCell)), same(cellState));
      expect(find.byType(HomeRankShelf), findsNothing);
      expect(
        tester
            .widget<ClassicHomeRankRail>(find.byType(ClassicHomeRankRail))
            .loading,
        isTrue,
      );
      pending.complete([_book(1, prefix: '完本'), _book(2, prefix: '完本')]);
      await tester.pumpAndSettle();
      expect(find.text('完本1'), findsOneWidget);
      expect(
        tester
            .widget<ClassicHomeRankRail>(find.byType(ClassicHomeRankRail))
            .selectedIndex,
        1,
      );
      style.value = AppThemeStyle.archive;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(HomeRankCell)), same(cellState));
      expect(find.byType(HomeRankShelf), findsOneWidget);
      expect(find.byKey(const Key('home_rank_flat_rail')), findsNothing);
      expect(find.text('完本1'), findsOneWidget);
      style.value = AppThemeStyle.classic;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ClassicHomeRankRail>(find.byType(ClassicHomeRankRail))
            .selectedIndex,
        1,
      );
      expect(find.text('完本1'), findsOneWidget);
      expect(calls, ['rank-1/100']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final initial in [0, 2]) {
    for (final swipe in [false, true]) {
      testWidgets('首页${swipe ? '滑动' : '点按'} $initial 到 1 下划线逐帧不越位', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              homeProvider.overrideWith(
                () => HomeNotifier(
                  usesLocalTabs: true,
                  initialTabIndex: initial,
                  homepageLoader:
                      ({
                        int tabType = 2,
                        int offset = 0,
                        String? sessionId,
                      }) async => const HomepagePage(
                        items: [],
                        nextOffset: null,
                        sessionId: null,
                      ),
                  searchLoader: (query, {int page = 1}) async => const [],
                ),
              ),
            ],
            child: _classic(const HomePage()),
          ),
        );
        await tester.pumpAndSettle();
        final indicator = find.byKey(const ValueKey('home_tab_indicator'));
        final targetTab = find.byKey(const ValueKey('home_category_1'));
        final target = tester.getCenter(targetTab).dx;
        final direction = initial == 0 ? 1 : -1;
        var previous = tester.getCenter(indicator).dx;
        if (swipe) {
          // 真分页的吸附阈值是半页（且起手会吃掉一个 touch slop）：拖够 24 格
          // 才稳稳越过中点，与 PiliPlus 的 TabBarView 一致。
          final gesture = await tester.startGesture(const Offset(180, 500));
          for (var frame = 0; frame < 24; frame++) {
            await gesture.moveBy(Offset(-10.0 * direction, 0));
            await tester.pump(const Duration(milliseconds: 16));
          }
          previous = tester.getCenter(indicator).dx;
          await gesture.up();
        } else {
          await tester.tap(targetTab);
        }
        await tester.pump();
        for (var frame = 0; frame < 45; frame++) {
          final centre = tester.getCenter(indicator).dx;
          expect(
            (centre - target) * direction,
            lessThanOrEqualTo(0.1),
            reason: '第 $frame 帧越过目标',
          );
          expect(
            (centre - previous) * direction,
            greaterThanOrEqualTo(-0.1),
            reason: '第 $frame 帧反向回弹',
          );
          previous = centre;
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(tester.widget<TabSwipeArea>(find.byType(TabSwipeArea)).index, 1);
        expect(previous, closeTo(target, 0.1));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'cached neighbouring tabs cannot bring archive slivers into classic home',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final style = ValueNotifier(AppThemeStyle.archive);
      addTearDown(style.dispose);
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      var loads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeProvider.overrideWith(
              () => HomeNotifier(
                usesLocalTabs: true,
                indexedHomepageLoader:
                    ({
                      int tabType = 2,
                      int offset = 0,
                      String? sessionId,
                      int? tabIndex,
                      int? lastTabIndex,
                    }) async {
                      loads++;
                      final items = [
                        for (var i = 1; i <= 20; i++)
                          _book(i, prefix: '分类$tabIndex-'),
                      ];
                      return HomepagePage(
                        items: items,
                        cells: [
                          HomeCell(
                            showType: 385,
                            name: '',
                            id: '$tabType',
                            style: const {},
                            items: items,
                            children: const [],
                          ),
                        ],
                        nextOffset: null,
                        sessionId: null,
                        answeredTabType: tabType,
                        tabScoped: true,
                      );
                    },
                searchLoader: (query, {int page = 1}) async => const [],
              ),
            ),
          ],
          child: _switchable(style, const HomePage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home_category_1')));
      await tester.pumpAndSettle();
      final pageState = tester.state(find.byType(HomePage));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomePage)),
      );
      final feed = container.read(homeProvider);
      final before = loads;
      expect(find.byType(HomeSectionLabel, skipOffstage: false), findsWidgets);
      style.value = AppThemeStyle.classic;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(HomePage)), same(pageState));
      expect(container.read(homeProvider), same(feed));
      expect(container.read(homeProvider).tabIndex, 1);
      expect(loads, before);
      // 回到已经挂载过的分类：页面子树保活，但按新皮肤重建，不能留下
      // 档案主题的区块组件，也不能重新发请求。
      await tester.tap(find.byKey(const ValueKey('home_category_0')));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(HomePage)), same(pageState));
      expect(loads, before);
      expect(find.byType(HomeMasthead), findsNothing);
      expect(find.byType(HomeHero), findsOneWidget);
      expect(find.byType(HomeSectionLabel), findsNothing);
      expect(find.byType(ClassicHomeSkeleton), findsNothing);
      final cards = tester.widgetList<HomeMediaCard>(
        find.byType(HomeMediaCard),
      );
      expect(cards, isNotEmpty);
      expect(
        cards.every(
          (card) =>
              card.item.title.startsWith('分类0-') &&
              card.radius == 12 &&
              card.titleSize == 15,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('首页标签条到排行榜标题的留白不超过 24dp，且不放重复的分类名', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              usesLocalTabs: true,
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: [for (var i = 1; i <= 12; i++) _book(i)],
                    cells: [_rankCell()],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: _classic(const HomePage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 标签文字底部 → 排行榜标题顶部。旧值 37.5，中间一片空白。
    final tabText = tester.getRect(find.text('推荐').first);
    final title = tester.getRect(find.text('排行榜').first);
    final gap = title.top - tabText.bottom;
    expect(gap, lessThanOrEqualTo(24), reason: '标签到排行榜标题空出了 $gap dp');
    expect(gap, greaterThan(12), reason: '压得太狠会贴着标签文字');

    // 非「推荐」分类不再用分类名当分区头：网格就是第一段。排行榜区块自己的
    // 标题（「排行榜」）仍在，但页面里不应再出现第二个「小说」。
    await tester.tap(find.byKey(const ValueKey('home_category_1')));
    await tester.pumpAndSettle();
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('排行榜'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('排行榜标题到榜单标签的留白不超过 24dp，且热区仍是 48dp（#384 回归）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              usesLocalTabs: true,
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: [for (var i = 1; i <= 12; i++) _book(i)],
                    cells: [_rankCell()],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: _classic(const HomePage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 标题文字底部 → 「推荐榜」文字顶部。#372 把「更多」的 48dp 热区塞进
    // 标题行、榜单标签的 48dp 热区居中排，这里曾空到 48.5dp。修复后标题
    // 行只由文字决定、下方 padding 归零，标签热区上下各留 12.7dp。0
    final title = tester.getRect(find.text('排行榜').first);
    final board = tester.getRect(find.text('推荐榜').first);
    final gap = board.top - title.bottom;
    expect(gap, lessThanOrEqualTo(20), reason: '标题到榜单标签空出了 $gap dp');
    expect(gap, greaterThanOrEqualTo(8), reason: '压得太狠会贴着标题');

    // 下划线底部 → 第一张卡片顶部：热区下缘的 12.7dp 空白就是全部间距，
    // 不再叠 SizedBox。曾因标签内容贴顶把热区剩余高度全堆在这里（37.4dp）。
    final boardColumn = find
        .ancestor(of: find.text('推荐榜'), matching: find.byType(Column))
        .first;
    final underline = tester.getRect(
      find.descendant(of: boardColumn, matching: find.byKey(_indicatorKey)),
    );
    final firstCard = tester.getRect(
      find.byKey(const ValueKey('rank:book:榜书-1')),
    );
    final cardGap = firstCard.top - underline.bottom;
    expect(cardGap, lessThanOrEqualTo(20), reason: '下划线到卡片空出了 $cardGap dp');
    expect(cardGap, greaterThanOrEqualTo(8), reason: '压得太狠会贴着下划线');

    // 触控尺寸与语义没有回退：「更多」48×48 仍完整，标签热区高度 ≥ 48。
    final more = find.byType(ClassicHomeBlockMore);
    expect(tester.getSize(more), const Size(48, 48));
    final boardTap = find
        .ancestor(of: find.text('推荐榜'), matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(boardTap).height, 48);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(more).flagsCollection.isButton,
      isTrue,
      reason: '「更多」必须保留按钮语义',
    );
    handle.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('多榜单横向滚到底时，最后一个标签的点击不被「更多」截获', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var selected = -1;
    var more = 0;
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: [for (var i = 1; i <= 9; i++) '榜单$i'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (i) => selected = i,
          onOpen: (_) {},
          onMore: () => more++,
        ),
      ),
    );
    // 横向滚到底：最后一个标签右缘停在列表的右侧 padding 处（与卡片
    // 同一条 gutter）。
    await tester.drag(find.text('榜单1'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    // 标签文字（y 44~60）与「更多」热区（y 8~56）有垂直重叠；未让位时
    // 滚到底的最后标签会钻到热区下面，这一下会命中「更多」而非标签。
    await tester.tap(find.text('榜单9'));
    expect(selected, 8, reason: '最后标签的点击不能被「更多」热区截获');
    expect(more, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单榜单不渲染标签行，标题到卡片保持紧凑', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var opened = 0;
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: const ['推荐榜'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (_) {},
          onOpen: (_) => opened++,
          onMore: () {},
        ),
      ),
    );
    // 只有一个榜单没有可选项：标签行不渲染，间距回退到 homeHeaderGap
    // 与「让开 48dp 热区」两者的较大值（约 25dp）。
    expect(find.text('推荐榜'), findsNothing);
    final title = tester.getRect(find.text('排行榜'));
    final card = tester.getRect(find.byKey(const ValueKey('rank:book:榜书-1')));
    final gap = card.top - title.bottom;
    expect(gap, inInclusiveRange(8, 32), reason: '单榜单标题到卡片空出了 $gap dp');
    // 没有标签行时，「更多」的 48dp 热区（y 8~56）只能借标题行下方的
    // 间距。卡片必须整体从热区底部之下开始，否则最后一张卡片右上角的
    // 点击会被「更多」截获（卡片横向排到右缘时与热区 x 范围重叠）。
    final lastCard = tester.getRect(
      find.byKey(const ValueKey('rank:book:榜书-3')),
    );
    await tester.tapAt(Offset(lastCard.right - 10, lastCard.top + 4));
    expect(opened, 1, reason: '最后一张卡片顶部的点击被「更多」热区截获');
    expect(tester.takeException(), isNull);
  });

  testWidgets('榜单标签行两端与标题、卡片对齐（左右 gutter 一致）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var selected = -1;
    var more = 0;
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: [for (var i = 1; i <= 9; i++) '榜单$i'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (i) => selected = i,
          onOpen: (_) {},
          onMore: () => more++,
        ),
      ),
    );
    // 标签文字在 48dp 热区里左右各内缩 10dp；列表两端抵消这段内缩后，
    // 首个标签的文字应与标题、卡片封面落在同一条竖线上（修复前左端会
    // 多出 10dp 空位）。
    final title = tester.getRect(find.text('排行榜'));
    final first = tester.getRect(find.text('榜单1'));
    final firstCard = tester.getRect(
      find.byKey(const ValueKey('rank:book:榜书-1')),
    );
    final gutter = title.left;
    expect(first.left, closeTo(gutter, 1), reason: '首个标签文字左缘应贴齐标题');
    expect(firstCard.left, closeTo(gutter, 1), reason: '卡片左缘是参照物');
    // 内缩上限 10dp 的直接护栏：sidePadding 会跟着 inset 同步变化，首尾
    // 对齐断言对 inset 的具体取值不敏感（10 改 8 仍贴 gutter）；只有
    // 「盒宽 − 文字宽 = 2 × 内缩」能暴露误改（改成 8 会缩到 16，48dp
    // 热区与标签间距随之静默变化）。用相对差值，不依赖字体绝对度量。
    expect(
      _boardWell(tester, '榜单1').width - first.width,
      closeTo(20, 0.01),
      reason: '盒宽 = 文字宽 + 2 × 10dp 内缩',
    );

    // 滚到最右：最后一个标签的文字右缘应与卡片右留白（同一条 gutter）
    // 对齐。修复前右侧让位 76dp，滚到头会空出一大截。宽度取自组件
    // 实际尺寸，不跟着 setSurfaceSize 里的字面量走。
    final railWidth = tester.getSize(find.byType(ClassicHomeRankRail)).width;
    await tester.drag(find.text('榜单1'), const Offset(-1200, 0));
    await tester.pumpAndSettle();
    final last = tester.getRect(find.text('榜单9'));
    expect(
      last.right,
      closeTo(railWidth - gutter, 1),
      reason: '最后一个标签文字右缘应与卡片右留白对齐',
    );

    // 标签行盖在「更多」热区上层，但按钮的视觉内容在标题行内，点它必须
    // 仍命中「更多」；标签行是 translucent，重叠区里落在标签上的点击归
    // 标签，落在标签外空白的点击放行给下层「更多」（见下一个用例）。
    final moreRect = tester.getRect(find.byType(ClassicHomeBlockMore));
    await tester.tapAt(Offset(moreRect.center.dx, moreRect.top + 6));
    expect(more, 1, reason: '「更多」的视觉区域必须仍可点');
    await tester.tap(find.text('榜单9'));
    expect(selected, 8, reason: '最后标签的点击不能被「更多」截获');
    expect(more, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签行与「更多」热区重叠的空白处，点击仍落到「更多」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var selected = -1;
    var more = 0;
    // 2 字榜名：文字 26dp + 左右内缩 20dp < 48dp，热区盒恒为 48dp，
    // 标签位置与字体度量无关；9 个共 476dp（6 + 9×48 + 8×4 + 6），超出
    // 390dp 视口，标签行占满全宽（这正是「更多」热区会被遮住的真实场景）。
    const boardNames = ['推荐', '完本', '新书', '飙升', '热搜', '口碑', '收藏', '连载', '完结'];
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: boardNames,
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (i) => selected = i,
          onOpen: (_) {},
          onMore: () => more++,
        ),
      ),
    );
    final moreRect = _moreRect(tester);
    // 「更多」热区 x 326~374 落在标签行下方，找一个同时落在热区内的
    // 标签空隙（4dp）。标签行若保持默认 opaque，这个空隙会被整块吞掉、
    // 点击丢失；translucent 才会放行下层「更多」。
    final gapX = _gapInMoreHotspot(tester, boardNames);
    expect(gapX, isNotNull, reason: '需要至少一个落在「更多」热区内的标签空隙');
    // y = top + 32 ≈ 40：既在标签行的 48dp 热区内（否则根本点不到标签行，
    // 也就测不到 translucent），又在「更多」热区（y 8~56）下半的重叠区。
    // 任一侧布局变了都要让这条用例失败，而不是静默变成点空气。
    final probeY = moreRect.top + 32;
    final firstInk = _boardWell(tester, boardNames.first);
    expect(firstInk.top, lessThan(probeY), reason: '探测点必须落在标签热区内');
    expect(firstInk.bottom, greaterThan(probeY), reason: '探测点必须落在标签热区内');
    await tester.tapAt(Offset(gapX!, probeY));
    expect(more, 1, reason: '重叠区空隙的点击应落到下层「更多」');
    expect(selected, -1, reason: '空隙处不应误选标签');
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签行重叠区的空隙处拖动，仍滚动标签行而不是交给「更多」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var more = 0;
    const boardNames = ['推荐', '完本', '新书', '飙升', '热搜', '口碑', '收藏', '连载', '完结'];
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: boardNames,
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (_) {},
          onOpen: (_) {},
          onMore: () => more++,
        ),
      ),
    );
    final moreRect = _moreRect(tester);
    final before = tester.getRect(find.text('推荐')).left;
    // 与上一条用例同一个空隙（热区内的 4dp 标签间隙）。translucent 只把
    // 空白处的点击放行给「更多」，滚动层仍留在命中结果里：横向拖动必须
    // 继续滚动标签行，否则「轻点让位、拖动失效」会变成另一种坏交互。
    final gapX = _gapInMoreHotspot(tester, boardNames);
    expect(gapX, isNotNull, reason: '需要至少一个落在「更多」热区内的标签空隙');
    await tester.dragFrom(
      Offset(gapX!, moreRect.top + 32),
      const Offset(-120, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('推荐')).left,
      lessThan(before - 60),
      reason: '空隙处的横向拖动应继续滚动标签行',
    );
    expect(more, 0, reason: '拖动不应触发「更多」');
    expect(tester.takeException(), isNull);
  });

  testWidgets('重名榜名时空隙定位按出现顺序取值，不会错位', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var selected = -1;
    var more = 0;
    // 生产数据榜名唯一，但 helper 必须能处理重名：9 个同名 2 字榜名让
    // find.text 一次匹配 9 个 Text，occurrence 若不按出现顺序递增，相邻
    // 标签的左右缘会取成同一个盒，空隙候选点也会落错。
    const boardNames = ['推荐', '推荐', '推荐', '推荐', '推荐', '推荐', '推荐', '推荐', '推荐'];
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: boardNames,
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (i) => selected = i,
          onOpen: (_) {},
          onMore: () => more++,
        ),
      ),
    );
    final first = _boardWell(tester, boardNames[0], occurrence: 0);
    final second = _boardWell(tester, boardNames[1], occurrence: 1);
    expect(
      second.left,
      closeTo(first.right + 4, 0.01),
      reason: 'occurrence 必须区分先后：第二个标签紧跟在第一个之后',
    );
    expect(first.width, 48, reason: '2 字同名标签仍是 48dp 热区');
    final gapX = _gapInMoreHotspot(tester, boardNames);
    expect(gapX, isNotNull, reason: '重名榜名也必须能找到「更多」热区内的空隙');
    await tester.tapAt(Offset(gapX!, _moreRect(tester).top + 32));
    expect(more, 1, reason: '重名榜名的空隙点击应落到「更多」');
    expect(selected, -1, reason: '空隙处不应误选标签');
    expect(tester.takeException(), isNull);
  });

  testWidgets('3 字榜名占满热区时，热区下半的点击归标签（标签优先）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var selected = -1;
    var more = 0;
    // 3 字榜名盒宽 59dp（文字 39 + 内缩 20），第 6 个标签占 x 321~380，
    // 把「更多」热区（x 326~374）整个盖住。这是内容溢出时的真实场景：
    // translucent 只保证「点击不丢失到滚动层」，点热区下半会切换榜单，
    // 热区并没有恢复完整的 48dp——把现状固定下来，避免误以为已修好。
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: [for (var i = 1; i <= 9; i++) '榜单$i'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (i) => selected = i,
          onOpen: (_) {},
          onMore: () => more++,
        ),
      ),
    );
    final moreRect = tester.getRect(find.byType(ClassicHomeBlockMore));
    // 热区顶边 +6 落在标题行（y 8~31.75）里，仍是「更多」；下半 +32
    // 落在标签行（约 31.75~79.75）里，被第 6 个标签全宽覆盖。
    await tester.tapAt(Offset(moreRect.center.dx, moreRect.top + 6));
    expect(more, 1, reason: '标题行里的「更多」视觉区域必须可点');
    await tester.tapAt(Offset(moreRect.center.dx, moreRect.top + 32));
    expect(selected, 5, reason: '热区下半落在第 6 个标签上，应切换榜单');
    expect(more, 1, reason: '标签优先：这一次不触发「更多」');
    // 滚到最右：末标签（x 336~384）压住热区下半，标题行里的「更多」
    // 仍必须可点（此前只在初始位置验证过）。
    await tester.drag(find.text('榜单1'), const Offset(-1600, 0));
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(moreRect.center.dx, moreRect.top + 6));
    expect(more, 2, reason: '滚到最右后标题行里的「更多」仍必须可点');
    await tester.tapAt(Offset(moreRect.center.dx, moreRect.top + 32));
    expect(selected, 8, reason: '热区下半落在末标签上，应切换榜单');
    expect(more, 2, reason: '末标签仍优先于「更多」');
    expect(tester.takeException(), isNull);
  });

  testWidgets('textScale 0.8 下标签盒仍为 48dp，重叠区空隙也能点到「更多」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var more = 0;
    const boardNames = ['推荐', '完本', '新书', '飙升', '热搜', '口碑', '收藏', '连载', '完结'];
    await tester.pumpWidget(
      _classic(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(0.8)),
            child: ClassicHomeRankRail(
              title: '排行榜',
              names: boardNames,
              selectedIndex: 0,
              books: [for (var i = 1; i <= 3; i++) _book(i)],
              loading: false,
              onSelect: (_) {},
              onOpen: (_) {},
              onMore: () => more++,
            ),
          ),
        ),
      ),
    );
    // 2 字字样缩到 20.8dp，仍不足最小触控盒，标签位置与 1.0 时相同；
    // 空隙可点靠的是 translucent，与文字缩放无关，这里固定住这个前提。
    final firstInk = _boardWell(tester, '推荐');
    expect(firstInk.size, const Size(48, 48), reason: '文字缩小后标签盒仍为 48dp');
    final moreRect = _moreRect(tester);
    final gapX = _gapInMoreHotspot(tester, boardNames);
    expect(gapX, isNotNull, reason: '缩小文字后热区内仍应有标签空隙');
    await tester.tapAt(Offset(gapX!, moreRect.top + 32));
    expect(more, 1, reason: 'textScale 0.8 下重叠区空隙仍应落到「更多」');
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中下划线居中于标签文字（3 字 / 2 字 / 单字）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    // 期望值依赖 flutter_test 默认字体（每字宽 = 字号，固定系数）；换字体
    // 或真机度量后需要重算。三组分别覆盖首标签 start、末标签 end 两个
    // 分支（#384 之后下划线随 Column 对齐一起贴边是视觉回归）。
    final cases = <(List<String>, String, String)>[
      ([for (var i = 1; i <= 9; i++) '榜单$i'], '榜单1', '榜单9'),
      (['推荐', '完本', '新书', '飙升', '热搜', '口碑', '收藏', '连载', '完结'], '推荐', '完结'),
      (['榜', '单', '剧', '新', '热', '收', '连', '完', '终'], '榜', '终'),
    ];
    void expectCentered(String label) {
      final text = tester.getRect(find.text(label));
      final indicator = _boardIndicator(tester, label);
      expect(
        indicator.center.dx,
        closeTo(text.center.dx, 1),
        reason: '$label 的下划线偏离文字中心 ${indicator.center.dx - text.center.dx}dp',
      );
      // 文字底 → 下划线顶固定 5dp：Stack 的 bottom padding 是「间距 + 高」，
      // 只改总高不会让 #384 用例变红，这条断言直接钉住两段间距。
      expect(
        indicator.top - text.bottom,
        closeTo(_expectedIndicatorGap, 0.5),
        reason: '$label 的文字与下划线间距',
      );
      // 文字宽于 16dp 时下划线必须是完整 16dp；单字会被夹到文字宽。
      if (text.width > 16) {
        expect(indicator.width, closeTo(16, 0.01), reason: '$label 的下划线宽度');
      } else {
        expect(
          indicator.width,
          closeTo(text.width, 0.5),
          reason: '$label 的单字下划线应被夹到文字宽（记录的取舍）',
        );
      }
    }

    for (final (names, first, last) in cases) {
      await tester.pumpWidget(
        _classic(
          ClassicHomeRankRail(
            // 每轮换 key：否则 element 复用会带着上一轮滚到最右的位置。
            key: ValueKey('rank-indicator-$first'),
            title: '排行榜',
            names: names,
            selectedIndex: 0,
            books: [for (var i = 1; i <= 3; i++) _book(i)],
            loading: false,
            onSelect: (_) {},
            onOpen: (_) {},
            onMore: () {},
          ),
        ),
      );
      expectCentered(first);
      await tester.drag(find.text(first), const Offset(-1600, 0));
      await tester.pumpAndSettle();
      expectCentered(last);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('中间标签（center 分支）下划线居中，选中态切换只换色不换位置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    const boardNames = ['推荐', '完本', '新书', '飙升', '热搜', '口碑', '收藏', '连载', '完结'];
    var selected = 0;
    await tester.pumpWidget(
      _classic(
        StatefulBuilder(
          builder: (context, setState) => ClassicHomeRankRail(
            title: '排行榜',
            names: boardNames,
            selectedIndex: selected,
            books: [for (var i = 1; i <= 3; i++) _book(i)],
            loading: false,
            onSelect: (i) => setState(() => selected = i),
            onOpen: (_) {},
            onMore: () {},
          ),
        ),
      ),
    );
    // 首/末标签走 start/end 分支（上一个用例已覆盖），中间的标签走
    // center：48dp 热区比 2 字文字宽 26dp 宽，若 Stack 被改回平铺，
    // 指示条会跟 Column 的居中项一起偏移。这里用第 5 个标签直接钉住
    // 「文字在热区里居中 + 指示条在文字里居中」这条 center 路径。
    final mid = boardNames[4];
    final midText = tester.getRect(find.text(mid));
    final midWell = _boardWell(tester, mid);
    expect(
      midText.center.dx,
      closeTo(midWell.center.dx, 0.5),
      reason: '中间标签的文字应居中于 48dp 热区',
    );
    expect(
      _boardIndicator(tester, mid).center.dx,
      closeTo(midText.center.dx, 1),
      reason: '中间标签的下划线应居中于文字',
    );

    Color indicatorColor(String name) =>
        (_boardIndicatorWidget(tester, name).decoration! as BoxDecoration)
            .color!;
    final ink = HomePalette.of(
      tester.element(find.byType(ClassicHomeRankRail)),
    ).ink;
    expect(indicatorColor(mid), Colors.transparent, reason: '未选中标签不应有下划线');
    expect(indicatorColor(boardNames.first), ink, reason: '初始选中第 0 个');
    final beforeRect = _boardIndicator(tester, mid);
    await tester.tap(find.text(mid));
    await tester.pumpAndSettle();
    expect(selected, 4, reason: '点击中间标签应回调对应下标');
    // 换选中后文字 w500→w700、muted→ink，但中心与下划线位置不变：
    // 下划线只切颜色，不会跳到别的标签上。
    expect(indicatorColor(mid), ink, reason: '选中后中间标签的下划线应是 ink');
    expect(
      indicatorColor(boardNames.first),
      Colors.transparent,
      reason: '原选中标签的下划线应恢复透明',
    );
    final afterRect = _boardIndicator(tester, mid);
    expect(
      afterRect.center.dx,
      closeTo(beforeRect.center.dx, 0.01),
      reason: '选中态切换不应横向移动下划线',
    );
    expect(
      afterRect.top,
      closeTo(beforeRect.top, 0.01),
      reason: '选中态切换不应纵向移动下划线',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('榜名不满屏时「更多」整块 48×48 都可点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var more = 0;
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: [for (var i = 1; i <= 3; i++) '榜单$i'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (_) {},
          onOpen: (_) {},
          onMore: () => more++,
        ),
      ),
    );
    // 3 个 3 字榜名内容约 197dp 不足一屏：标签行视口 shrink-wrap 到内容
    // 宽，右侧空白不在视口内，「更多」热区（x 326~374）整块露出来。这是
    // translucent 之外的另一条路径：视口根本没盖住热区。
    final viewport = tester.getSize(find.byType(SingleChildScrollView));
    expect(viewport.width, lessThan(320), reason: '标签行应 shrink-wrap 到内容宽');
    final moreRect = _moreRect(tester);
    for (final dy in const [4.0, 24.0, 44.0]) {
      await tester.tapAt(Offset(moreRect.center.dx, moreRect.top + dy));
    }
    expect(more, 3, reason: '不满屏时「更多」热区的上/中/下都必须可点');
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签行重叠带内的竖向拖动滚页面，不滚标签行也不触发「更多」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var more = 0;
    const boardNames = ['推荐', '完本', '新书', '飙升', '热搜', '口碑', '收藏', '连载', '完结'];
    await tester.pumpWidget(
      _classic(
        SingleChildScrollView(
          child: Column(
            children: [
              ClassicHomeRankRail(
                title: '排行榜',
                names: boardNames,
                selectedIndex: 0,
                books: [for (var i = 1; i <= 3; i++) _book(i)],
                loading: false,
                onSelect: (_) {},
                onOpen: (_) {},
                onMore: () => more++,
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    final moreRect = _moreRect(tester);
    final titleTop = tester.getRect(find.text('排行榜')).top;
    final railLeft = tester.getRect(find.text('推荐')).left;
    // 重叠带（y ≈ 40）在标签行的命中路径里，但竖向拖动应由外层页面
    // 赢得竞技场：标签行只认水平方向，竖向不能被它截走，也不能点中「更多」。
    await tester.dragFrom(
      Offset(moreRect.center.dx, moreRect.top + 32),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('排行榜')).top,
      lessThan(titleTop - 100),
      reason: '重叠带内的竖向拖动应滚动页面',
    );
    expect(
      tester.getRect(find.text('推荐')).left,
      closeTo(railLeft, 0.01),
      reason: '标签行不应横向滚动',
    );
    expect(more, 0, reason: '拖动不应触发「更多」');
    expect(tester.takeException(), isNull);
  });

  testWidgets('textScale 1.5 下单字榜名仍两端对齐且下划线居中', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _classic(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: ClassicHomeRankRail(
              title: '排行榜',
              names: const ['榜', '单', '剧', '新', '热', '收', '连', '完', '终'],
              selectedIndex: 0,
              books: [for (var i = 1; i <= 3; i++) _book(i)],
              loading: false,
              onSelect: (_) {},
              onOpen: (_) {},
              onMore: () {},
            ),
          ),
        ),
      ),
    );
    // 1.5× 下单字文字 19.5dp > 16dp：指示条不再被夹窄，且首标签仍贴
    // gutter（盒宽 48 > 文字 + 内缩）。19.5dp 依赖 flutter_test 默认字体
    // （每字宽 = 字号）这一前提，换字体后需重算。
    final title = tester.getRect(find.text('排行榜'));
    final railWidth = tester.getSize(find.byType(ClassicHomeRankRail)).width;
    final first = tester.getRect(find.text('榜'));
    expect(first.left, closeTo(title.left, 1), reason: '1.5× 下首标签仍贴 gutter');
    final indicator = _boardIndicator(tester, '榜');
    expect(indicator.width, closeTo(16, 0.01), reason: '1.5× 单字下划线应是完整 16dp');
    expect(indicator.center.dx, closeTo(first.center.dx, 1));
    await tester.drag(find.text('榜'), const Offset(-1600, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('终')).right,
      closeTo(railWidth - title.left, 1),
      reason: '1.5× 下末标签仍贴卡片右留白',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有 2 个榜名时首末分支同时成立（没有居中项）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          // index 0 走 start，index 1 同时是 end（names.length − 1）。
          names: const ['推荐榜', '完本榜'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (_) {},
          onOpen: (_) {},
          onMore: () {},
        ),
      ),
    );
    // 2 个标签内容约 134dp 不满屏：视口 shrink-wrap 到内容宽，首标签
    // 贴左 gutter、末标签贴视口右缘的 gutter（不是屏幕右缘）。
    final title = tester.getRect(find.text('排行榜'));
    final viewport = tester.getSize(find.byType(SingleChildScrollView));
    expect(
      tester.getRect(find.text('推荐榜')).left,
      closeTo(title.left, 1),
      reason: '2 个榜名时首标签仍贴左 gutter',
    );
    expect(
      tester.getRect(find.text('完本榜')).right,
      closeTo(viewport.width - title.left, 1),
      reason: '2 个榜名时末标签仍贴内容右端的 gutter',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('gutter 小于文字内缩时，内缩收窄且首尾文字仍落在 gutter 上', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    // gutter 8 < 默认内缩 10：只把两端补偿改成 min 还不够，标签内缩也
    // 必须跟着收到 min(10, gutter)，否则 Padding 会拿到负值直接崩。
    // 生产恒为 homeGutter=16 走不到这条分支，参数化后才有护栏。
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: const ['推荐榜', '完本榜'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (_) {},
          onOpen: (_) {},
          onMore: () {},
          gutter: 8,
        ),
      ),
    );
    final title = tester.getRect(find.text('排行榜'));
    expect(title.left, 8, reason: '标题应使用传入的 gutter 8');
    expect(
      tester.getRect(find.text('推荐榜')).left,
      closeTo(8, 1),
      reason: 'gutter < 内缩时首标签文字仍贴 8dp 边距',
    );
    // 2 个 3 字榜名内容约 114dp 不满屏：视口 shrink-wrap 到内容宽。
    final viewport = tester.getSize(find.byType(SingleChildScrollView));
    expect(
      tester.getRect(find.text('完本榜')).right,
      closeTo(viewport.width - 8, 1),
      reason: 'gutter < 内缩时末标签文字仍贴内容右端的 8dp',
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('rank:book:榜书-1'))).left,
      closeTo(8, 1),
      reason: '卡片行必须与标签行共用同一个 gutter',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('短榜名（单字）首标签仍与标题对齐', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          // 单字文字宽 13dp，内容宽 33dp < 48dp 的触控盒：若内容居中，
          // 文字会被推到 6 + (48 − 13) / 2 = 23.5dp（偏 7.5dp）。
          names: const ['榜', '单', '剧'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (_) {},
          onOpen: (_) {},
          onMore: () {},
        ),
      ),
    );
    final title = tester.getRect(find.text('排行榜'));
    final first = tester.getRect(find.text('榜'));
    expect(
      first.left,
      closeTo(title.left, 1),
      reason: '短榜名的首标签文字不能被 48dp 热区居中推开',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('短榜名（单字）末标签右端仍与卡片右留白对齐', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          // 单字：盒宽仍是 48dp（内容 33dp < 48dp），9 个共 476dp 可滚动。
          // 末标签走 end 分支；若改回居中，文字右缘会比 gutter 多出
          // (48 − 13) / 2 − 10 = 7.5dp，closeTo(…, 1) 会立刻失败。
          names: const ['榜', '单', '剧', '新', '热', '收', '连', '完', '终'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (_) {},
          onOpen: (_) {},
          onMore: () {},
        ),
      ),
    );
    final title = tester.getRect(find.text('排行榜'));
    final railWidth = tester.getSize(find.byType(ClassicHomeRankRail)).width;
    await tester.drag(find.text('榜'), const Offset(-1600, 0));
    await tester.pumpAndSettle();
    final last = tester.getRect(find.text('终'));
    expect(
      last.right,
      closeTo(railWidth - title.left, 1),
      reason: '单字末标签的文字右缘应贴齐卡片右留白',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签行两端对齐在 textScale 0.8 / 1.5 下仍成立', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    for (final scale in const [0.8, 1.5]) {
      await tester.pumpWidget(
        _classic(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: ClassicHomeRankRail(
                // 每轮换 key：否则 element 复用会带着上一轮滚到最右的
                // 位置，首标签还在屏外，左缘断言失去意义。
                key: ValueKey('rank-rail-scale-$scale'),
                title: '排行榜',
                names: [for (var i = 1; i <= 9; i++) '榜单$i'],
                selectedIndex: 0,
                books: [for (var i = 1; i <= 3; i++) _book(i)],
                loading: false,
                onSelect: (_) {},
                onOpen: (_) {},
                onMore: () {},
              ),
            ),
          ),
        ),
      );
      final title = tester.getRect(find.text('排行榜'));
      final first = tester.getRect(find.text('榜单1'));
      expect(
        first.left,
        closeTo(title.left, 1),
        reason: 'textScale $scale：首标签文字左缘应贴齐标题',
      );
      final railWidth = tester.getSize(find.byType(ClassicHomeRankRail)).width;
      await tester.drag(find.text('榜单1'), const Offset(-1600, 0));
      await tester.pumpAndSettle();
      final last = tester.getRect(find.text('榜单9'));
      expect(
        last.right,
        closeTo(railWidth - title.left, 1),
        reason: 'textScale $scale：末标签文字右缘应与卡片右留白对齐',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('textScale 2.0 下标签行仍两端对齐且下划线居中', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    // 2.0× 是无障碍字号的常见上限：2 字榜名文字宽 52dp，标签盒 72dp，
    // 9 个共约 692dp 远超 390dp 视口。期望值依赖 flutter_test 默认字体
    // （每字宽 = 字号 × 缩放），换字体后需重算。
    await tester.pumpWidget(
      _classic(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2.0)),
            child: ClassicHomeRankRail(
              title: '排行榜',
              names: const [
                '推荐',
                '完本',
                '新书',
                '飙升',
                '热搜',
                '口碑',
                '收藏',
                '连载',
                '完结',
              ],
              selectedIndex: 0,
              // 卡片行在 2.0× 下会撑破 railHeight 的既有公式（本次改动未
              // 触碰 _RankCard，溢出 0.4dp 属既有问题），这里留空以隔离
              // 标签行的对齐断言。
              books: const [],
              loading: false,
              onSelect: (_) {},
              onOpen: (_) {},
              onMore: () {},
            ),
          ),
        ),
      ),
    );
    final title = tester.getRect(find.text('排行榜'));
    final railWidth = tester.getSize(find.byType(ClassicHomeRankRail)).width;
    final first = tester.getRect(find.text('推荐'));
    expect(first.left, closeTo(title.left, 1), reason: '2.0× 下首标签仍贴 gutter');
    final indicator = _boardIndicator(tester, '推荐');
    expect(
      indicator.width,
      closeTo(16, 0.01),
      reason: '2.0× 下文字宽远超 16dp，下划线应是完整 16dp',
    );
    expect(
      indicator.center.dx,
      closeTo(first.center.dx, 1),
      reason: '2.0× 下下划线仍居中于文字',
    );
    await tester.drag(find.text('推荐'), const Offset(-1600, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('完结')).right,
      closeTo(railWidth - title.left, 1),
      reason: '2.0× 下末标签仍贴卡片右留白',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 320dp 下九个榜名两端对齐仍成立', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: [for (var i = 1; i <= 9; i++) '榜单$i'],
          selectedIndex: 0,
          books: [for (var i = 1; i <= 3; i++) _book(i)],
          loading: false,
          onSelect: (_) {},
          onOpen: (_) {},
          onMore: () {},
        ),
      ),
    );
    final title = tester.getRect(find.text('排行榜'));
    final railWidth = tester.getSize(find.byType(ClassicHomeRankRail)).width;
    final first = tester.getRect(find.text('榜单1'));
    expect(first.left, closeTo(title.left, 1), reason: '窄屏下首标签仍贴齐标题');
    await tester.drag(find.text('榜单1'), const Offset(-1600, 0));
    await tester.pumpAndSettle();
    final last = tester.getRect(find.text('榜单9'));
    expect(
      last.right,
      closeTo(railWidth - title.left, 1),
      reason: '窄屏下末标签文字右缘仍贴齐卡片右留白',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading 态标签行两端仍与标题、卡片对齐', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _classic(
        ClassicHomeRankRail(
          title: '排行榜',
          names: [for (var i = 1; i <= 9; i++) '榜单$i'],
          selectedIndex: 0,
          books: const [],
          loading: true,
          onSelect: (_) {},
          onOpen: (_) {},
          onMore: () {},
        ),
      ),
    );
    // 数据未到时标签行照常渲染：对齐规则与 loading 无关，不能被加载分支
    // 吃掉。转圈是无限动画，这里不能用 pumpAndSettle。
    final title = tester.getRect(find.text('排行榜'));
    final railWidth = tester.getSize(find.byType(ClassicHomeRankRail)).width;
    final first = tester.getRect(find.text('榜单1'));
    expect(first.left, closeTo(title.left, 1), reason: 'loading 态首标签仍贴齐标题');
    await tester.drag(find.text('榜单1'), const Offset(-1600, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    final last = tester.getRect(find.text('榜单9'));
    expect(
      last.right,
      closeTo(railWidth - title.left, 1),
      reason: 'loading 态末标签文字右缘仍贴齐卡片右留白',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('空榜名与单榜名的 loading 态都不渲染标签行且不崩', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    // 数据未到时 names 可能是空列表（homeRankNames 返回空）或单个榜名：
    // 都不满足 names.length > 1，不应出现标签行；loading 分支只画转圈，
    // 卡片列表也不存在。转圈是无限动画，用 pump 而不是 pumpAndSettle。
    final cases = <(String, List<String>)>[
      ('empty', const []),
      ('single', const ['推荐榜']),
    ];
    for (final (label, names) in cases) {
      await tester.pumpWidget(
        _classic(
          ClassicHomeRankRail(
            key: ValueKey('rank-rail-loading-$label'),
            title: '排行榜',
            names: names,
            selectedIndex: 0,
            books: const [],
            loading: true,
            onSelect: (_) {},
            onOpen: (_) {},
            onMore: () {},
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byType(SingleChildScrollView),
        findsNothing,
        reason: '$label：少于 2 个榜名不应渲染标签行',
      );
      expect(
        find.byKey(const Key('classic_home_rank_rail')),
        findsNothing,
        reason: '$label：loading 态不应渲染卡片列表',
      );
      expect(find.text('排行榜'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'classic loading, error and stream footer have no archive vocabulary',
    (tester) async {
      await tester.pumpWidget(
        _classic(
          SingleChildScrollView(
            child: Column(
              children: [
                const ClassicHomeFeedLoading(),
                ClassicHomeFeedError(
                  headline: '故事还在路上',
                  message: '暂时无法加载推荐，稍后再试一次。',
                  detail: 'offline',
                  onRetry: () async {},
                ),
                const ClassicHomeStreamFooter.loading(),
                ClassicHomeStreamFooter.retry(onRetry: () {}),
                const ClassicHomeStreamFooter.done(),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(HomeCode), findsNothing);
      expect(find.text('正在刷新内容'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('加载中...'), findsOneWidget);
      expect(find.text('加载失败，点击重试'), findsOneWidget);
      expect(find.text('已显示全部内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
