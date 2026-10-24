import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/home/home_cell_blocks.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

/// Regression cover for the scroll cost of the home feed.
///
/// Both tests here fail against the version that measured the grid from inside
/// a `SliverLayoutBuilder`: a sliver's constraints carry the scroll offset, so
/// they differ on every scroll frame, which re-ran the builder and rebuilt
/// every visible card (plus its `CachedNetworkImage`) for the whole scroll.
void main() {
  MediaItem item(int index) => MediaItem(
    id: 'b$index',
    title: '小说 $index',
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: 'book',
  );

  Future<void> pumpFeed(
    WidgetTester tester, {
    int count = 40,
    double textScale = 1.0,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
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
                    items: [for (var i = 0; i < count; i++) item(i)],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  int gridColumns(WidgetTester tester) {
    final grid = tester.widget<SliverGrid>(
      find.byType(SliverGrid, skipOffstage: false),
    );
    return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
        .crossAxisCount;
  }

  Map<Key, HomeEntrance> entrances(WidgetTester tester) => {
    for (final element in find.byType(HomeEntrance).evaluate())
      if ((element.widget as HomeEntrance).key case final Key key)
        key: element.widget as HomeEntrance,
  };

  testWidgets('the grid is measured outside the sliver, not per scroll frame', (
    tester,
  ) async {
    await pumpFeed(tester);
    expect(
      find.byType(SliverLayoutBuilder),
      findsNothing,
      reason: 'a sliver-scoped measurement rebuilds the grid every frame',
    );
    expect(find.byType(SliverGrid), findsOneWidget);
    // The feed hands the cell width down, so cards skip their own measurement.
    final cards = tester
        .widgetList<HomeMediaCard>(find.byType(HomeMediaCard))
        .toList();
    expect(cards, isNotEmpty);
    for (final card in cards) {
      expect(card.coverWidth, isNotNull);
    }
  });

  testWidgets('changing text scale rebuilds the cached grid geometry', (
    tester,
  ) async {
    final textScale = ValueNotifier(1.0);
    addTearDown(textScale.dispose);
    await tester.binding.setSurfaceSize(const Size(400, 800));
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
                    items: [for (var i = 0; i < 40; i++) item(i)],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: ValueListenableBuilder<double>(
          valueListenable: textScale,
          builder: (context, scale, _) => MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const HomePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(gridColumns(tester), 3);

    textScale.value = 1.8;
    await tester.pumpAndSettle();
    expect(
      gridColumns(tester),
      2,
      reason:
          'a 1.8× scale on a 400-wide phone must drop to two columns; '
          'reusing the sliver instance would keep the old 3-column delegate',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling the feed does not rebuild the mounted cards', (
    tester,
  ) async {
    await pumpFeed(tester);
    final before = entrances(tester);
    expect(before, isNotEmpty);

    await tester.drag(find.byKey(const Key('home_feed')), const Offset(0, -60));
    await tester.pumpAndSettle();

    final after = entrances(tester);
    final stayed = before.keys.toSet().intersection(after.keys.toSet());
    expect(stayed, isNotEmpty, reason: 'the drag must leave cards mounted');
    for (final key in stayed) {
      expect(
        identical(before[key], after[key]),
        isTrue,
        reason: '$key was rebuilt just because the feed scrolled',
      );
    }
  });

  testWidgets('a re-mounted card does not replay its entrance animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HomeEntrance(key: Key('entrance'), child: Text('第一条')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: HomeEntrance(
          key: Key('entrance'),
          animate: false,
          child: Text('第一条'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(find.text('第一条'), findsOneWidget);
  });

  testWidgets('a pagination state flip does not rebuild the mounted block cards', (
    tester,
  ) async {
    // The block pipeline (rank strip + staggered stream) must reuse its
    // content slivers across the `isLoadMore` flip the same way the legacy
    // grid short-circuits through `_gridSliverFor`: the flip publishes a new
    // state carrying the same cells instance, and rebuilding the block list
    // with a fresh child delegate would rebuild every mounted card twice per
    // page load (`SliverChildBuilderDelegate.shouldRebuild` is always true).
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    MediaItem book(String id) => MediaItem(
      id: id,
      title: id,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );

    final releasePage2 = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        homeProvider.overrideWith(
          () => HomeNotifier(
            homepageLoader:
                ({
                  int tabType = 2,
                  int offset = 0,
                  String? sessionId,
                }) async {
                  if (offset == 0) {
                    return HomepagePage(
                      items: const [],
                      cells: [
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
                              items: [for (var i = 0; i < 8; i++) book('p1-$i')],
                              children: const [],
                            ),
                          ],
                        ),
                      ],
                      nextOffset: 1,
                      sessionId: null,
                    );
                  }
                  await releasePage2.future;
                  return HomepagePage(
                    items: [book('p2-0'), book('p2-1')],
                    nextOffset: null,
                    sessionId: null,
                  );
                },
            searchLoader: (query, {int page = 1}) async => const [],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: HomePage(scrollController: controller)),
      ),
    );
    await tester.pumpAndSettle();

    Map<Key, HomeBookCard> cards() => {
      for (final element in find.byType(HomeBookCard).evaluate())
        if ((element.widget as HomeBookCard).key case final Key key)
          key: element.widget as HomeBookCard,
    };
    final before = cards();
    expect(before, isNotEmpty);

    // Page 2 hangs on the completer, so the `isLoadMore: true` frame — the
    // state flip this test protects — is observable on its own.
    unawaited(container.read(homeProvider.notifier).loadMore());
    await tester.pump();

    final during = cards();
    final stayed = before.keys.toSet().intersection(during.keys.toSet());
    expect(stayed, isNotEmpty, reason: 'the flip must leave cards mounted');
    for (final key in stayed) {
      expect(
        identical(before[key], during[key]),
        isTrue,
        reason: '$key was rebuilt by a pagination state flip alone',
      );
    }

    releasePage2.complete();
    await tester.pumpAndSettle();
    // The append is a new cells instance, so the stream must grow: jumping to
    // the bottom lays the second page's cards in and scrolls them on screen.
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('p2-0'), findsOneWidget);
    // The bottom jump started another pagination cycle; let its 500ms poll
    // timer and the 2s snapshot debounce expire so none stays pending.
    await tester.pump(const Duration(seconds: 3));
  });

}
