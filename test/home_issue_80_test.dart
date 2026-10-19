import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/widgets/home/home_filter.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_resume_card.dart';

void main() {
  group('Issue #80: Home Feed Filter Model', () {
    final items = [
      MediaItem(
        id: '1',
        title: '作品 1',
        cover: '',
        author: '作者 A',
        badge: '',
        ep: '更新至 10 集',
        kind: 'book',
        score: 7.5,
      ),
      MediaItem(
        id: '2',
        title: '作品 2',
        cover: '',
        author: '作者 B',
        badge: '',
        ep: '全本完结',
        kind: 'book',
        score: 9.2,
      ),
      MediaItem(
        id: '3',
        title: '作品 3',
        cover: '',
        author: '作者 C',
        badge: '',
        ep: '连载中',
        kind: 'book',
        score: 8.8,
      ),
    ];

    test('minScore filter works correctly', () {
      const filter = HomeFeedFilter(minScore: 8.5);
      final result = filter.apply(items);
      expect(result.map((e) => e.id), ['2', '3']);
    });

    test('finished status filter works correctly', () {
      const filter = HomeFeedFilter(status: 'finished');
      final result = filter.apply(items);
      expect(result.map((e) => e.id), ['2']);
    });

    test('serial status filter works correctly', () {
      const filter = HomeFeedFilter(status: 'serial');
      final result = filter.apply(items);
      expect(result.map((e) => e.id), ['1', '3']);
    });

    test('未完结 is serial, not finished', () {
      final serial = MediaItem(
        id: 'serial',
        title: '连载作品',
        cover: '',
        author: '',
        badge: '',
        ep: '未完结',
        kind: 'book',
      );
      const finishedFilter = HomeFeedFilter(status: 'finished');
      const serialFilter = HomeFeedFilter(status: 'serial');

      expect(finishedFilter.apply([serial]), isEmpty);
      expect(serialFilter.apply([serial]), [serial]);
    });

    test('unknown status is not guessed as serial', () {
      final unknown = MediaItem(
        id: 'unknown',
        title: '状态未知',
        cover: '',
        author: '',
        badge: '',
        ep: '第 10 集',
        kind: 'video',
      );
      const serialFilter = HomeFeedFilter(status: 'serial');

      expect(serialFilter.apply([unknown]), isEmpty);
    });

    test('score sort works correctly', () {
      const filter = HomeFeedFilter(sort: 'score');
      final result = filter.apply(items);
      expect(result.map((e) => e.id), ['2', '3', '1']);
    });
  });

  group('Issue #80: Cover score badge', () {
    testWidgets('shows score badge in bottom right when score exists', (
      tester,
    ) async {
      final withScore = MediaItem(
        id: '1',
        title: '高分小说',
        cover: '',
        author: '知名作者',
        badge: '',
        ep: '全本',
        kind: 'book',
        score: 9.6,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 140,
                child: HomeMediaCard(
                  item: withScore,
                  coverWidth: 140,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      final score = find.byKey(const Key('home_card_score'));
      final cover = find.byKey(const Key('home_card_cover'));
      expect(score, findsOneWidget);
      expect(cover, findsOneWidget);
      expect(find.text('9.6'), findsOneWidget);

      final scoreRect = tester.getRect(score);
      final coverRect = tester.getRect(cover);
      expect(coverRect.contains(scoreRect.center), isTrue);
      expect(scoreRect.right, greaterThan(coverRect.center.dx));
      expect(scoreRect.bottom, greaterThan(coverRect.center.dy));
    });

    testWidgets('hides score badge when score is null', (tester) async {
      final noScore = MediaItem(
        id: '2',
        title: '无评分作品',
        cover: '',
        author: '新人作者',
        badge: '',
        ep: '第 1 集',
        kind: 'video',
        score: null,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 140,
                child: HomeMediaCard(
                  item: noScore,
                  coverWidth: 140,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('home_card_score')), findsNothing);
    });
  });

  group('Issue #80: Scroll to top signal', () {
    testWidgets('HomePage.scrollToTop() scrolls controller back to offset 0', (
      tester,
    ) async {
      final longFeed = [
        for (var i = 0; i < 30; i++)
          MediaItem(
            id: 'item_$i',
            title: '作品 $i',
            cover: '',
            author: '作者 $i',
            badge: '',
            ep: '第 $i 章',
            kind: 'book',
            score: 8.0 + (i % 20) / 10,
          ),
      ];

      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

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
                      items: longFeed,
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

      final scrollable = find.byKey(const Key('home_feed'));
      expect(scrollable, findsOneWidget);

      final scrollableFinder = find
          .descendant(
            of: find.byKey(const Key('home_feed')),
            matching: find.byType(Scrollable),
          )
          .first;

      // Scroll down
      await tester.drag(scrollable, const Offset(0, -600));
      await tester.pumpAndSettle();

      final scrollState = tester.state<ScrollableState>(scrollableFinder);
      expect(scrollState.position.pixels, greaterThan(200));

      // Trigger scroll to top
      HomePage.scrollToTop();
      await tester.pumpAndSettle();

      expect(scrollState.position.pixels, 0.0);
    });
  });

  group('Issue #80: Category filtering on HomePage', () {
    testWidgets('the filter sheet narrows and resets the feed', (tester) async {
      final mixedItems = [
        // 3 for spotlight
        MediaItem(
          id: 's1',
          title: '焦点 1',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
        MediaItem(
          id: 's2',
          title: '焦点 2',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
        MediaItem(
          id: 's3',
          title: '焦点 3',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
        // 值得一看 feed
        MediaItem(
          id: 'r1',
          title: '低分连载书',
          cover: '',
          author: '作者 1',
          badge: '',
          ep: '更新至 10 集',
          kind: 'book',
          score: 7.2,
        ),
        MediaItem(
          id: 'r2',
          title: '高分完结书',
          cover: '',
          author: '作者 2',
          badge: '',
          ep: '全本完结',
          kind: 'book',
          score: 9.5,
        ),
      ];

      await tester.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var loaderCalls = 0;
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
                    }) async {
                      if (loaderCalls++ == 0) {
                        return HomepagePage(
                          items: mixedItems,
                          nextOffset: null,
                          sessionId: null,
                        );
                      }
                      return const HomepagePage(
                        items: [],
                        nextOffset: null,
                        sessionId: null,
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

      // Initially both items in "值得一看" are present
      expect(find.text('低分连载书'), findsOneWidget);
      expect(find.text('高分完结书'), findsOneWidget);

      // Filters live in one sheet now: the default feed has no chip row.
      Future<void> applyChoice(String label) async {
        await tester.tap(find.byKey(const Key('home_section_filter_button')));
        await tester.pumpAndSettle();
        expect(find.text('只筛选「为你推荐」列表；上方焦点区保持编辑精选。'), findsOneWidget);
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
      }

      await applyChoice('8.5 分及以上');

      // Only "高分完结书" remains.
      expect(find.text('高分完结书'), findsOneWidget);
      expect(find.text('低分连载书'), findsNothing);
      expect(find.text('为你推荐 · 8.5 分以上'), findsOneWidget);

      await applyChoice('已完结');
      expect(find.text('高分完结书'), findsOneWidget);
      expect(find.text('低分连载书'), findsNothing);

      // Reset inside the sheet, then apply the reset locally.
      await tester.tap(find.byKey(const Key('home_section_filter_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.text('低分连载书'), findsOneWidget);
      expect(find.text('高分完结书'), findsOneWidget);
    });

    testWidgets('active filter waits for an explicit load more', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final offsets = <int>[];
      var failNextPage = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeProvider.overrideWith(
              () => HomeNotifier(
                initialTabIndex: 1,
                homepageLoader:
                    ({
                      int tabType = 2,
                      int offset = 0,
                      String? sessionId,
                    }) async {
                      offsets.add(offset);
                      if (offset == 0) {
                        return HomepagePage(
                          items: [
                            for (var index = 0; index < 30; index++)
                              MediaItem(
                                id: 'low-$index',
                                title: '低分作品 $index',
                                cover: '',
                                author: '',
                                badge: '',
                                ep: '连载中',
                                kind: 'book',
                                score: 6.0,
                              ),
                          ],
                          nextOffset: 1,
                          sessionId: 'session',
                        );
                      }
                      if (failNextPage) {
                        failNextPage = false;
                        throw const ApiException('load more failed');
                      }
                      return HomepagePage(
                        items: [
                          MediaItem(
                            id: 'high',
                            title: '后页高分作品',
                            cover: '',
                            author: '',
                            badge: '',
                            ep: '全本',
                            kind: 'book',
                            score: 9.2,
                          ),
                        ],
                        nextOffset: null,
                        sessionId: 'session',
                      );
                    },
                searchLoader: (query, {int page = 1}) async =>
                    throw const ApiException('search failed'),
              ),
            ),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(offsets, [0]);

      final filterButton = find.byKey(const Key('home_section_filter_button'));
      await tester.ensureVisible(filterButton);
      await tester.pumpAndSettle();
      await tester.tap(filterButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('8.5 分及以上'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.text('没有符合条件的内容'), findsOneWidget);
      expect(offsets, [0]);

      await tester.tap(find.byKey(const Key('home_filter_load_more')));
      await tester.pumpAndSettle();
      expect(offsets, [0, 1]);
      expect(find.text('加载失败，点击重试'), findsOneWidget);

      await tester.tap(find.byKey(const Key('home_filter_load_more')));
      await tester.pumpAndSettle();
      expect(offsets, [0, 1, 1]);
      expect(find.text('后页高分作品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('category tabs name their own filter scope', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

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
                        for (var index = 0; index < 5; index++)
                          MediaItem(
                            id: 'book-$index',
                            title: '小说 $index',
                            cover: '',
                            author: '',
                            badge: '',
                            ep: '全本',
                            kind: 'book',
                            score: 8.0 + index / 10,
                          ),
                      ],
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

      await tester.tap(find.byKey(const ValueKey('home_category_1')));
      await tester.pumpAndSettle();
      final filterButton = find.byKey(const Key('home_section_filter_button'));
      await tester.ensureVisible(filterButton);
      await tester.pumpAndSettle();
      await tester.tap(filterButton);
      await tester.pumpAndSettle();

      expect(find.text('只筛选「更多小说」列表；上方焦点区保持编辑精选。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('eink toggle repaints the cached home grid', (tester) async {
    einkModeNotifier.value = false;
    addTearDown(() => einkModeNotifier.value = false);
    final items = [
      for (var index = 0; index < 5; index++)
        MediaItem(
          id: 'eink-$index',
          title: '作品 $index',
          cover: '',
          author: '作者',
          badge: '',
          ep: '第 1 章',
          kind: 'book',
          score: 9.0,
        ),
    ];

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
                    items: items,
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: ValueListenableBuilder<bool>(
          valueListenable: einkModeNotifier,
          builder: (context, _, _) => MaterialApp(home: HomePage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Color scoreBackground() {
      final badge = tester.widget<Container>(
        find.byKey(const Key('home_card_score')).first,
      );
      return (badge.decoration! as BoxDecoration).color!;
    }

    expect(scoreBackground(), isNot(Colors.white));
    einkModeNotifier.value = true;
    await tester.pumpAndSettle();
    expect(scoreBackground(), Colors.white);
    expect(tester.takeException(), isNull);
  });

  group('HomeResumeCard', () {
    late Directory directory;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('fqapp-home-resume-');
      Hive.init(directory.path);
      await LibraryStore.instance.init();
    });

    tearDown(() async {
      await Hive.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () => const <void>[],
      );
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // Temp cleanup failure is unrelated to the assertion under test.
      }
    });

    testWidgets('tiny reading progress is not shown as 0%', (tester) async {
      await tester.runAsync(() async {
        await LibraryStore.instance.addHistory({
          'id': 'tiny-home',
          'kind': 'book',
          'title': '刚翻开',
          'episode': 0,
          'progress': 0.002,
          'time': DateTime.now().millisecondsSinceEpoch,
        });
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HomeResumeCard(onOpen: (_) {})),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('已读 <1%'), findsOneWidget);
      expect(find.text('已读 0%'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
