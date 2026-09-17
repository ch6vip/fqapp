import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/home/ambient_backdrop.dart';
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

  Future<void> pumpFeed(WidgetTester tester, {int count = 40}) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                      HomepagePage(
                        items: [for (var i = 0; i < count; i++) item(i)],
                        nextOffset: null,
                        sessionId: null,
                      ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
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

  testWidgets('the ambient wash is not rebuilt for every scroll frame', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFFFCFAF7),
          body: Stack(
            children: [
              Positioned.fill(child: AmbientBackdrop(scroll: controller)),
              ListView(
                controller: controller,
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 100, child: Text('$i')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    CustomPaint wash() => tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(AmbientBackdrop),
        matching: find.byType(CustomPaint),
      ),
    );

    final before = wash().painter;
    expect(before, isNotNull);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
    expect(
      identical(before, wash().painter),
      isTrue,
      reason: 'the wash should be translated, not repainted, while scrolling',
    );
  });
}
