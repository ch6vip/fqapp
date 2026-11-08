import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/home_feed_cache.dart';
import 'package:fqapp/widgets/home/home_archive.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_masthead.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_rank_shelf.dart';
import 'package:fqapp/widgets/home/home_reading_row.dart';
import 'package:fqapp/widgets/home/home_shelf.dart';

MediaItem _book(int index) => MediaItem(
  id: '$index',
  title: '小说 $index',
  cover: '',
  author: '作者',
  badge: '',
  ep: '',
  kind: 'book',
);

ThemeData _theme(AppThemeStyle style, {bool dark = false}) => ThemeData(
  brightness: dark ? Brightness.dark : Brightness.light,
  extensions: [AppStyleTokens.forStyle(style)],
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

Finder _coverClip(Finder card) =>
    find.descendant(of: card, matching: find.byType(ClipRRect)).first;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HomeFeedCache.hiveReady = false;
  });
  tearDown(() => HomeFeedCache.hiveReady = false);

  test('archive defaults and OLED/e-ink priority remain unchanged', () {
    expect(const HomePalette(false).canvas, const Color(0xFFF4F3EF));
    expect(const HomePalette(false).surface, const Color(0xFFFDFCFA));
    expect(const HomePalette(true).canvas, const Color(0xFF191919));
    expect(const HomePalette(true).surface, const Color(0xFF242424));
    for (final style in AppThemeStyle.values) {
      final oled = HomePalette(true, oled: true, style: style);
      expect(oled.canvas, Colors.black);
      expect(oled.surface, const Color(0xFF0C0C0E));
      final eink = HomePalette(true, oled: true, eink: true, style: style);
      expect(eink.canvas, Colors.white);
      expect(eink.surface, Colors.white);
      expect(eink.ink, Colors.black);
      expect(eink.line, Colors.black);
      expect(
        HomePalette(false, oled: true, style: style).canvas,
        HomePalette(false, style: style).canvas,
      );
    }
  });

  testWidgets('HomePalette reads classic colours from inherited tokens', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      late HomePalette palette;
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(AppThemeStyle.classic, dark: dark),
          themeAnimationDuration: Duration.zero,
          home: Builder(
            builder: (context) {
              palette = HomePalette.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(palette.style, AppThemeStyle.classic);
      expect(palette.canvas, Color(dark ? 0xFF171719 : 0xFFF7F6F2));
      expect(palette.surface, Color(dark ? 0xFF242427 : 0xFFFFFFFF));
      expect(palette.grid, Colors.transparent);
    }
  });

  testWidgets('classic removes decorative headers and their reserved gaps', (
    tester,
  ) async {
    final style = ValueNotifier(AppThemeStyle.archive);
    addTearDown(style.dispose);
    await tester.pumpWidget(
      _switchable(
        style,
        Scaffold(
          body: Column(
            children: [
              HomeMasthead(onSearch: () {}, onCategory: () {}),
              const HomeSectionLabel(code: '01 / FOR YOU', title: '为你推荐'),
            ],
          ),
        ),
      ),
    );
    final label = find.byType(HomeSectionLabel);
    final archiveHeight = tester.getSize(label).height;
    final codeHeight = tester.getSize(find.text('01 / FOR YOU')).height;
    expect(find.text(HomeMasthead.brandCode), findsOneWidget);
    style.value = AppThemeStyle.classic;
    await tester.pumpAndSettle();
    expect(find.text(HomeMasthead.brandCode), findsNothing);
    expect(find.text('01 / FOR YOU'), findsNothing);
    expect(find.text(HomeMasthead.brand), findsOneWidget);
    expect(find.text('为你推荐'), findsOneWidget);
    expect(
      tester.getSize(label).height,
      closeTo(archiveHeight - codeHeight - 4, .01),
    );
    expect(find.byKey(const Key('home_search_button')), findsOneWidget);
    expect(find.byKey(const Key('home_category_button')), findsOneWidget);
    style.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    expect(find.text(HomeMasthead.brandCode), findsOneWidget);
    expect(tester.getSize(label).height, archiveHeight);
  });

  for (final scale in [1.0, 1.8]) {
    testWidgets('card extent/radius match the actual rows at scale $scale', (
      tester,
    ) async {
      final heights = <AppThemeStyle, double>{};
      for (final style in AppThemeStyle.values) {
        late double extent;
        await tester.pumpWidget(
          MaterialApp(
            theme: _theme(style),
            themeAnimationDuration: Duration.zero,
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Center(
                    child: Builder(
                      builder: (context) {
                        extent = homeCardExtent(
                          context,
                          120,
                          TextScaler.linear(scale),
                        );
                        return SizedBox(
                          width: 120,
                          child: HomeMediaCard(
                            item: _book(1),
                            onTap: () {},
                            coverWidth: 120,
                            titleSize: homeCardTitleSize,
                            radius: AppStyleTokens.of(context).coverRadius,
                            archiveCode: 'NOV-00001',
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final card = find.byType(HomeMediaCard);
        final classic = style == AppThemeStyle.classic;
        final clip = tester.widget<ClipRRect>(_coverClip(card));
        expect(clip.borderRadius, BorderRadius.circular(classic ? 10 : 3));
        expect(find.text('NOV-00001'), classic ? findsNothing : findsOneWidget);
        expect(find.text('作者'), findsOneWidget);
        final height = tester.getSize(card).height;
        heights[style] = height;
        // Preserve the existing 2dp grid allowance, not a hidden code row.
        expect(extent - height, closeTo(2, 1.1));
        if (classic) {
          final titleTop = tester.getTopLeft(find.text('小说 1')).dy;
          final metaTop = tester.getTopLeft(find.text('作者')).dy;
          expect(
            metaTop - titleTop,
            closeTo(homeCardTitleSize * scale * 1.35 * 2 + 4, .01),
          );
        }
        expect(tester.takeException(), isNull);
      }
      expect(
        heights[AppThemeStyle.archive]! - heights[AppThemeStyle.classic]!,
        closeTo(3 + homeCardCodeSize * scale * 1.35, 1.1),
      );
    });
  }

  testWidgets('continue panel rounds without changing progress or actions', (
    tester,
  ) async {
    var opened = 0;
    var dismissed = 0;
    final semantics = tester.ensureSemantics();
    try {
      final style = ValueNotifier(AppThemeStyle.archive);
      addTearDown(style.dispose);
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
      BoxDecoration decoration() => tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(HomeContinueRow),
              matching: find.byType(Container),
            ),
          )
          .map((container) => container.decoration)
          .whereType<BoxDecoration>()
          .single;
      expect(decoration().borderRadius, BorderRadius.circular(4));
      style.value = AppThemeStyle.classic;
      await tester.pumpAndSettle();
      expect(decoration().borderRadius, BorderRadius.circular(16));
      expect(find.text('CONTINUE / 读到 第3章'), findsNothing);
      expect(find.text('继续阅读 · 读到 第3章'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .4,
      );
      await tester.tap(find.text('小说 1'));
      await tester.tap(find.bySemanticsLabel('隐藏继续阅读'));
      expect(opened, 1);
      expect(dismissed, 1);
      await tester.pumpAndSettle();
    } finally {
      semantics.dispose();
    }
  });

  for (final flat in [false, true]) {
    testWidgets(
      'ranking survives a style switch on ${flat ? 'flat' : '3D'} shelf',
      (tester) async {
        final style = ValueNotifier(AppThemeStyle.archive);
        addTearDown(style.dispose);
        await tester.pumpWidget(
          _switchable(
            style,
            Scaffold(
              body: HomeRankShelf(
                books: [for (var i = 1; i <= 3; i++) _book(i)],
                onOpen: (_) {},
                flat: flat,
                stepped: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('home_rank_next')));
        await tester.pumpAndSettle();
        final shelfState = tester.state(find.byType(HomeRankShelf));
        style.value = AppThemeStyle.classic;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(HomeRankShelf)), same(shelfState));
        expect(find.text('NO.002'), findsWidgets);
        expect(find.text('02 / 03'), findsOneWidget);
        expect(find.text('小说 2'), findsOneWidget);
        if (flat) {
          expect(
            tester
                .widget<ClipRRect>(_coverClip(find.byType(HomeRankShelf)))
                .borderRadius,
            BorderRadius.circular(10),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final blocks in [false, true]) {
    testWidgets(
      '${blocks ? 'block' : 'fallback'} feed refreshes cached styling in place',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final style = ValueNotifier(AppThemeStyle.archive);
        final scroll = ScrollController();
        addTearDown(style.dispose);
        addTearDown(scroll.dispose);
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        final books = [for (var i = 1; i <= 40; i++) _book(i)];
        var loads = 0;
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
                      }) async {
                        loads++;
                        return HomepagePage(
                          items: books,
                          cells: blocks
                              ? [
                                  HomeCell(
                                    showType: 385,
                                    name: '',
                                    id: '',
                                    style: const {},
                                    items: books,
                                    children: const [],
                                  ),
                                ]
                              : const [],
                          nextOffset: null,
                          sessionId: null,
                        );
                      },
                  searchLoader: (query, {int page = 1}) async => const [],
                ),
              ),
            ],
            child: _switchable(style, HomePage(scrollController: scroll)),
          ),
        );
        await tester.pumpAndSettle();
        final pageState = tester.state(find.byType(HomePage));
        SliverGrid grid() => tester.widget<SliverGrid>(find.byType(SliverGrid));
        SliverGridDelegateWithFixedCrossAxisCount geometry() =>
            grid().gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        final archiveExtent = geometry().mainAxisExtent!;
        final archiveGrid = grid();
        final initialLoads = loads;
        expect(geometry().crossAxisCount, 3);
        expect(grid().delegate.estimatedChildCount, 40);
        scroll.jumpTo(100);
        await tester.pumpAndSettle();
        style.value = AppThemeStyle.classic;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 160));
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(HomePage)), same(pageState));
        expect(grid(), isNot(same(archiveGrid)));
        expect(scroll.offset, 100);
        expect(loads, initialLoads);
        expect(grid().delegate.estimatedChildCount, 40);
        expect(geometry().crossAxisCount, 3);
        expect(
          geometry().mainAxisExtent,
          closeTo(archiveExtent - 3 - homeCardCodeSize * 1.35, .01),
        );
        final cards = tester.widgetList<HomeMediaCard>(
          find.byType(HomeMediaCard),
        );
        expect(cards, isNotEmpty);
        expect(cards.every((card) => card.radius == 10), isTrue);
        expect(
          tester
              .widget<ClipRRect>(_coverClip(find.byType(HomeMediaCard).first))
              .borderRadius,
          BorderRadius.circular(10),
        );
        expect(find.textContaining('NOV-'), findsNothing);
        style.value = AppThemeStyle.archive;
        await tester.pumpAndSettle();
        expect(geometry().mainAxisExtent, archiveExtent);
        expect(
          tester.widget<HomeMediaCard>(find.byType(HomeMediaCard).first).radius,
          3,
        );
        expect(find.textContaining('NOV-'), findsWidgets);
        expect(scroll.offset, 100);
        expect(loads, initialLoads);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
