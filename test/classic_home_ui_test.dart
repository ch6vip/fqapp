import 'dart:async';

import 'package:flutter/material.dart';
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
      final underline = tester
          .widgetList<AnimatedContainer>(
            find.descendant(of: tab, matching: find.byType(AnimatedContainer)),
          )
          .last;
      expect(underline.constraints!.maxWidth, 16);
      expect(underline.constraints!.maxHeight, 2.5);
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
        find.descendant(of: boardColumn, matching: find.byType(Container)),
      );
      expect(underline.constraints!.maxWidth, 16);
      expect(underline.constraints!.maxHeight, 2);
      await tester.tap(find.text('更多'));
      expect(more, 1);
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
      List<Widget> preview(int index) {
        final swipe = tester.widget<TabSwipeArea>(find.byType(TabSwipeArea));
        final box = swipe.previewBuilder!(index) as ColoredBox;
        return (box.child as CustomScrollView).slivers;
      }

      expect(
        (preview(0).first as SliverToBoxAdapter).child,
        isA<HomeSectionLabel>(),
      );
      style.value = AppThemeStyle.classic;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(HomePage)), same(pageState));
      expect(container.read(homeProvider), same(feed));
      expect(container.read(homeProvider).tabIndex, 1);
      expect(loads, before);
      expect(
        (preview(0).single as SliverToBoxAdapter).child,
        isA<ClassicHomeSkeleton>(),
      );
      expect(find.byType(HomeMasthead), findsNothing);
      expect(find.byType(HomeHero), findsOneWidget);
      expect(find.byType(HomeSectionLabel), findsNothing);
      final cards = tester.widgetList<HomeMediaCard>(
        find.byType(HomeMediaCard),
      );
      expect(cards, isNotEmpty);
      expect(
        cards.every(
          (card) =>
              card.item.title.startsWith('分类1-') &&
              card.radius == 12 &&
              card.titleSize == 15,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

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
