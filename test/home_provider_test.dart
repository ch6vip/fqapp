import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/home_feed_cache.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

void main() {
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fqapp-home-provider-test-',
    );
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    HomeFeedCache.hiveReady = false;
  });

  test(
    'legacy manga search stops on duplicates without a real cursor',
    () async {
      final offsets = <int>[];
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          mangaSearchLoader: ({int offset = 0}) async {
            offsets.add(offset);
            return [
              SearchTab(
                title: '漫画',
                items: [_item('a', kind: 'manga')],
              ),
            ];
          },
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      await _loadTab(notifier, HomeNotifier.tabs.indexOf('漫画'));
      await notifier.loadMore();
      await notifier.loadMore();
      expect(offsets, [0, 10]);
      expect(container.read(provider).hasMore, isFalse);
    },
  );

  for (final tabIndex in [0, HomeNotifier.tabs.indexOf('漫画')]) {
    for (final middlePage in ['duplicate', 'empty', 'filtered']) {
      test(
        'manga cursor survives a $middlePage page in tab $tabIndex',
        () async {
          final offsets = <int>[];
          final provider = NotifierProvider<HomeNotifier, HomeState>(
            () => HomeNotifier(
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
              searchLoader: (query, {int page = 1}) async => [],
              mangaSearchLoader: ({int offset = 0}) async {
                offsets.add(offset);
                return [
                  SearchTab(
                    title: '漫画',
                    items: switch (offset) {
                      0 => [_item('a', kind: 'manga')],
                      17 => switch (middlePage) {
                        'duplicate' => [_item('a', kind: 'manga')],
                        'filtered' => [_item('other', kind: 'book')],
                        _ => [],
                      },
                      _ => [_item('b', kind: 'manga')],
                    },
                    hasMore: offset != 23,
                    nextOffset: offset == 0 ? 17 : 23,
                  ),
                ];
              },
            ),
          );
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final notifier = container.read(provider.notifier);
          await _loadTab(notifier, tabIndex);
          await notifier.loadMore();
          expect(container.read(provider).items.map((item) => item.id), ['a']);
          expect(container.read(provider).hasMore, isTrue);
          await notifier.loadMore();
          expect(container.read(provider).items.map((item) => item.id), [
            'a',
            'b',
          ]);
          await notifier.loadMore();
          expect(offsets, [0, 17, 23]);
          expect(container.read(provider).hasMore, isFalse);
        },
      );
    }
  }

  for (final nextOffset in [null, -1, 0, 17]) {
    test(
      'manga stops on an invalid cursor or explicit exhaustion ($nextOffset)',
      () async {
        final offsets = <int>[];
        final provider = NotifierProvider<HomeNotifier, HomeState>(
          () => HomeNotifier(
            mangaSearchLoader: ({int offset = 0}) async {
              offsets.add(offset);
              return [
                SearchTab(
                  title: '漫画',
                  items: [_item('a', kind: 'manga')],
                  hasMore: nextOffset != 17,
                  nextOffset: nextOffset,
                ),
              ];
            },
          ),
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(provider.notifier);
        await _loadTab(notifier, HomeNotifier.tabs.indexOf('漫画'));
        await notifier.loadMore();
        expect(offsets, [0]);
        expect(container.read(provider).hasMore, isFalse);
      },
    );
  }

  test('manga continues after an empty first page', () async {
    final offsets = <int>[];
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        mangaSearchLoader: ({int offset = 0}) async {
          offsets.add(offset);
          return [
            SearchTab(
              title: '漫画',
              items: offset == 0 ? [] : [_item('a', kind: 'manga')],
              hasMore: offset == 0,
              nextOffset: 17,
            ),
          ];
        },
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await _loadTab(notifier, HomeNotifier.tabs.indexOf('漫画'));
    expect(container.read(provider).hasMore, isTrue);
    await notifier.loadMore();
    expect(offsets, [0, 17]);
    expect(container.read(provider).items.map((item) => item.id), ['a']);
  });

  for (final recommendationAvailable in [true, false]) {
    test('manju follows search cursors across duplicate and filtered-empty '
        'pages (recommendation available: $recommendationAvailable)', () async {
      final offsets = <int>[];
      final homepageOffsets = <int>[];
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async {
                expect(tabType, 24);
                homepageOffsets.add(offset);
                if (!recommendationAvailable) throw StateError('unavailable');
                return HomepagePage(
                  items: [_item('a', kind: 'manju')],
                  nextOffset: null,
                  sessionId: null,
                );
              },
          searchLoader: (query, {int page = 1}) async =>
              throw StateError('wrong search'),
          manjuSearchLoader: ({int offset = 0}) async {
            offsets.add(offset);
            return [
              SearchTab(
                title: '短剧',
                items: switch (offset) {
                  0 => [_item('a', kind: 'manju')],
                  17 => [_item('live-action', kind: 'video')],
                  _ => [_item('b', kind: 'manju')],
                },
                hasMore: offset != 23,
                nextOffset: offset == 0 ? 17 : 23,
              ),
            ];
          },
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      await _loadTab(notifier, HomeNotifier.tabs.indexOf('漫剧'));
      if (recommendationAvailable) {
        expect(offsets, isEmpty);
        await notifier.loadMore();
      }
      expect(container.read(provider).hasMore, isTrue);
      await notifier.loadMore();
      expect(container.read(provider).items.map((item) => item.id), ['a']);
      expect(container.read(provider).hasMore, isTrue);
      await notifier.loadMore();
      expect(container.read(provider).items.map((item) => item.id), ['a', 'b']);
      expect(container.read(provider).hasMore, isFalse);
      await notifier.loadMore();
      expect(offsets, [0, 17, 23]);
      expect(homepageOffsets, [0]);
    });
  }

  test('manju stops when an empty search page repeats its cursor', () async {
    final offsets = <int>[];
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                const HomepagePage(
                  items: [],
                  nextOffset: null,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
        manjuSearchLoader: ({int offset = 0}) async {
          offsets.add(offset);
          return [
            SearchTab(title: '短剧', items: [], hasMore: true, nextOffset: 0),
          ];
        },
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await _loadTab(notifier, HomeNotifier.tabs.indexOf('漫剧'));
    await notifier.loadMore();
    expect(offsets, [0]);
    expect(container.read(provider).hasMore, isFalse);
  });

  for (final tabIndex in [0, HomeNotifier.tabs.indexOf('漫画')]) {
    test(
      'tab $tabIndex loads and pages actual manga results independently',
      () async {
        final requests = <int>[];
        final provider = NotifierProvider<HomeNotifier, HomeState>(
          () => HomeNotifier(
            homepageLoader:
                ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                    const HomepagePage(
                      items: [],
                      nextOffset: null,
                      sessionId: null,
                    ),
            searchLoader: (query, {int page = 1}) async {
              expect(query, isNot('漫画'));
              return [];
            },
            mangaSearchLoader: ({int offset = 0}) async {
              requests.add(offset);
              return [
                SearchTab(
                  title: '漫画',
                  items: [_item('manga-$offset', kind: 'manga')],
                ),
              ];
            },
          ),
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(provider.notifier);
        await _loadTab(notifier, tabIndex);
        await notifier.loadMore();
        expect(requests, [0, 10]);
        expect(container.read(provider).items.map((item) => item.id), [
          'manga-0',
          'manga-10',
        ]);
      },
    );
  }

  for (final tabIndex in [0, 1]) {
    final tabName = HomeNotifier.tabs[tabIndex];
    for (final initiallyEmpty in [false, true]) {
      test(
        '$tabName follows advancing cursors across duplicate and empty pages '
        '(initially empty: $initiallyEmpty)',
        () async {
          final offsets = <int>[];
          final sessions = <String?>[];
          final novelSearchPages = <int>[];
          final provider = NotifierProvider<HomeNotifier, HomeState>(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    // The combined feed reads the manju stream (24) for its
                    // manju group. Keep it empty here so this test tracks only
                    // the novel stream's cursor.
                    if (tabType != 2) {
                      return const HomepagePage(
                        items: [],
                        nextOffset: null,
                        sessionId: null,
                      );
                    }
                    offsets.add(offset);
                    sessions.add(sessionId);
                    return HomepagePage(
                      items: switch (offset) {
                        0 when initiallyEmpty => [],
                        0 || 1 => [_item('a')],
                        2 => [],
                        _ => [_item('b')],
                      },
                      nextOffset: offset < 3 ? offset + 1 : null,
                      sessionId: 'session-$offset',
                    );
                  },
              searchLoader: (query, {int page = 1}) async {
                if (query == '小说') novelSearchPages.add(page);
                return [];
              },
            ),
          );
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final notifier = container.read(provider.notifier);
          await _loadTab(notifier, tabIndex);
          expect(container.read(provider).hasMore, isTrue);
          for (var page = 1; page <= 2; page++) {
            await notifier.loadMore();
            expect(container.read(provider).items.map((item) => item.id), [
              'a',
            ]);
            expect(container.read(provider).hasMore, isTrue);
            expect(novelSearchPages, isEmpty);
          }
          await notifier.loadMore();
          expect(container.read(provider).items.map((item) => item.id), [
            'a',
            'b',
          ]);
          expect(offsets, [0, 1, 2, 3]);
          expect(sessions, [null, 'session-0', 'session-1', 'session-2']);

          await notifier.loadMore();
          expect(container.read(provider).hasMore, isFalse);
          await notifier.loadMore();
          expect(offsets, [0, 1, 2, 3]);
          expect(novelSearchPages, [1]);
        },
      );
    }

    for (final scenario in const [
      (requestedOffset: 0, nextOffset: 0, fresh: false),
      (requestedOffset: 0, nextOffset: -1, fresh: false),
      (requestedOffset: 1, nextOffset: 1, fresh: false),
      (requestedOffset: 1, nextOffset: 0, fresh: false),
      (requestedOffset: 1, nextOffset: 1, fresh: true),
      (requestedOffset: 1, nextOffset: 0, fresh: true),
    ]) {
      test('$tabName falls back after cursor ${scenario.requestedOffset} -> '
          '${scenario.nextOffset} (fresh items: ${scenario.fresh})', () async {
        final offsets = <int>[];
        final novelSearchPages = <int>[];
        final provider = NotifierProvider<HomeNotifier, HomeState>(
          () => HomeNotifier(
            homepageLoader:
                ({int tabType = 2, int offset = 0, String? sessionId}) async {
                  // Manju reads its own stream (24); leave it empty so the manju
                  // group falls back to search and this test keeps tracking the
                  // novel stream's cursor.
                  if (tabType != 2) {
                    return const HomepagePage(
                      items: [],
                      nextOffset: null,
                      sessionId: null,
                    );
                  }
                  offsets.add(offset);
                  final atInvalidCursor = offset == scenario.requestedOffset;
                  return HomepagePage(
                    items: [
                      _item(atInvalidCursor && scenario.fresh ? 'b' : 'a'),
                    ],
                    nextOffset: atInvalidCursor ? scenario.nextOffset : 1,
                    sessionId: 'session',
                  );
                },
            searchLoader: (query, {int page = 1}) async {
              if (query != '小说') return [];
              novelSearchPages.add(page);
              return [
                SearchTab(
                  title: query,
                  items: page == 1 ? [_item('search-book')] : [],
                ),
              ];
            },
          ),
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(provider.notifier);
        await _loadTab(notifier, tabIndex);
        for (var page = 0; page < 4; page++) {
          await notifier.loadMore();
        }
        expect(container.read(provider).items.map((item) => item.id), [
          'a',
          if (scenario.fresh) 'b',
          'search-book',
        ]);
        expect(offsets, [0, if (scenario.requestedOffset > 0) 1]);
        expect(novelSearchPages, [1, 2]);
        expect(container.read(provider).hasMore, isFalse);
      });
    }
  }

  test(
    'an initial request can finish after its provider is disposed',
    () async {
      final response = Completer<HomepagePage>();
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) =>
                  response.future,
          searchLoader: (query, {int page = 1}) async => const [],
        ),
      );
      final container = ProviderContainer();
      final request = container.read(provider.notifier).load();
      container.dispose();
      response.complete(
        HomepagePage(items: [_item('book')], nextOffset: null, sessionId: null),
      );
      await expectLater(request, completes);
    },
  );

  test('search fallback does not relabel other kinds as novels', () async {
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                throw StateError('recommendations unavailable'),
        searchLoader: (query, {int page = 1}) async => [
          SearchTab(title: '书籍', items: [_item('novel')]),
          SearchTab(
            title: '短剧',
            items: [_item('drama', kind: 'video')],
          ),
        ],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(provider.notifier).selectTab(1);
    await _flushMicrotasks();
    expect(container.read(provider).items.map((item) => item.id), ['novel']);
  });

  test('推荐流可用时首页只显示它自己的区块，不再混排其他来源', () async {
    // 官方书城 tab 只渲染自己的 block，不把短剧/漫画/听书交错进来。
    var searchCalls = 0;
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('rec-1'), _item('rec-2')],
                  cells: const [
                    HomeCell(
                      showType: 384,
                      name: '猜你喜欢',
                      id: '',
                      style: {},
                      items: [],
                      children: [],
                    ),
                  ],
                  nextOffset: null,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async {
          searchCalls++;
          return [
            SearchTab(title: '综合', items: [_item('search-$query')]),
          ];
        },
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(provider.notifier).load();
    final state = container.read(provider);

    // 只有推荐流的卡片，短剧/漫画/听书都不该被拉进来。
    expect(state.items.map((i) => i.id), ['rec-1', 'rec-2']);
    expect(state.cells, hasLength(1));
    expect(state.cells.single.name, '猜你喜欢');
    expect(searchCalls, 0, reason: '不再为混排去搜其他来源');
  });

  test('快照带区块时首帧即区块版，冷启动不再闪旧版网格', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(
      0,
      [_item('cached-1')],
      hasMore: true,
      cells: const [
        HomeCell(
          showType: 511,
          name: '排行榜',
          id: '',
          style: {},
          items: [],
          children: [],
        ),
      ],
    );

    final releaseNetwork = Completer<void>();
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async {
              await releaseNetwork.future;
              return HomepagePage(
                items: [_item('fresh-1')],
                cells: const [
                  HomeCell(
                    showType: 384,
                    name: '猜你喜欢',
                    id: '',
                    style: {},
                    items: [],
                    children: [],
                  ),
                ],
                nextOffset: null,
                sessionId: null,
              );
            },
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final loading = container.read(provider.notifier).load();

    // 首帧即区块版：网络还没回答，state.cells 就已经非空 —— home_page 的
    // 区块管线不再退回旧版聚光灯+平铺网格，冷启动不会先闪旧版首页。
    expect(container.read(provider).cells.map((cell) => cell.name), ['排行榜']);
    expect(container.read(provider).items.map((item) => item.id), ['cached-1']);

    releaseNetwork.complete();
    await loading;
    // 网络整页替换时 cells 照常跟着换（stale-while-revalidate 语义）。
    expect(container.read(provider).cells.map((cell) => cell.name), ['猜你喜欢']);
    expect(container.read(provider).items.map((item) => item.id), ['fresh-1']);
    await cache.close();
  });

  test('翻页失败置 error 而不是只置 hasMore（footer 重试的判定输入）', () async {
    // P1 回归：曾只置 hasMore=false，流尾会谎报「已显示全部内容」。
    // 页面 footer 的重试分支判定是 error != null && items.isNotEmpty。
    var page = 0;
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async {
              page += 1;
              if (page == 1) {
                return HomepagePage(
                  items: [_item('first-1')],
                  cells: const [
                    HomeCell(
                      showType: 384,
                      name: '',
                      id: '',
                      style: {},
                      items: [],
                      children: [
                        HomeCell(
                          showType: 385,
                          name: '',
                          id: '',
                          style: {},
                          items: [],
                          children: [],
                        ),
                      ],
                    ),
                  ],
                  nextOffset: 10,
                  sessionId: null,
                );
              }
              throw StateError('翻页失败');
            },
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(provider.notifier).load();

    await container.read(provider.notifier).loadMore();

    final state = container.read(provider);
    expect(state.error, isNotNull);
    expect(state.hasMore, isFalse);
    // 已有内容保留（错误页不清空列表）。
    expect(state.items.map((i) => i.id), ['first-1']);
  });

  test('追加页的书拼进流区块，网格真的无限', () async {
    // 区块管线只渲染 cells；分页响应不带区块，若新书只进 items，网格永远
    // 停在首页那批卡。追加页必须合入 385 流区块（cellsForView）。
    var page = 0;
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async {
              page += 1;
              if (page == 1) {
                return HomepagePage(
                  items: [_item('first-1'), _item('first-2')],
                  cells: const [
                    HomeCell(
                      showType: 384,
                      name: '猜你喜欢',
                      id: '',
                      style: {},
                      items: [],
                      children: [
                        HomeCell(
                          showType: 385,
                          name: '',
                          id: '',
                          style: {},
                          items: [],
                          children: [],
                        ),
                      ],
                    ),
                  ],
                  nextOffset: 10,
                  sessionId: null,
                );
              }
              // 续页：只有 items，没有 cells。
              return HomepagePage(
                items: [_item('next-1'), _item('next-2')],
                nextOffset: null,
                sessionId: null,
              );
            },
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(provider.notifier).load();

    final firstCells = container.read(provider).cells;
    expect(firstCells.single.showType, 384);
    expect(
      firstCells.single.children.single.items.map((i) => i.id),
      isEmpty,
    );

    await container.read(provider.notifier).loadMore();

    // 追加页的书出现在流区块的渲染列表里。
    final merged = container.read(provider).cells;
    expect(
      merged.single.children.single.items.map((i) => i.id),
      ['next-1', 'next-2'],
    );
    // items 也照常追加（旧管线/去重语义不变）。
    expect(
      container.read(provider).items.map((i) => i.id),
      ['first-1', 'first-2', 'next-1', 'next-2'],
    );
  });

  test('the combined feed keeps novels when recommendations fail', () async {
    final queries = <String>[];
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                throw StateError('old backend'),
        searchLoader: (query, {int page = 1}) async {
          queries.add('$query:$page');
          return [
            SearchTab(
              title: '综合',
              items: query == '小说' ? [_item('novel-$page')] : const [],
            ),
          ];
        },
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await notifier.load();
    expect(container.read(provider).items.map((item) => item.id), ['novel-1']);
    await notifier.loadMore();
    expect(container.read(provider).items.map((item) => item.id), [
      'novel-1',
      'novel-2',
    ]);
    expect(queries, containsAll(['小说:1', '小说:2']));
  });

  test('a late response cannot overwrite or populate another tab', () async {
    final requests = <int, List<Completer<HomepagePage>>>{};

    Future<HomepagePage> loadHomepage({
      int tabType = 2,
      int offset = 0,
      String? sessionId,
    }) {
      final completer = Completer<HomepagePage>();
      requests.putIfAbsent(tabType, () => []).add(completer);
      return completer.future;
    }

    Future<List<SearchTab>> loadSearch(String query, {int page = 1}) async =>
        const [];

    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () =>
          HomeNotifier(homepageLoader: loadHomepage, searchLoader: loadSearch),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);

    notifier.selectTab(1); // 小说, request still pending.
    expect(requests[2], hasLength(1));
    notifier.selectTab(2); // 短剧 supersedes it.
    expect(requests[8], hasLength(1));

    requests[8]!.single.complete(
      HomepagePage(items: [_item('video')], nextOffset: null, sessionId: null),
    );
    await _flushMicrotasks();
    expect(container.read(provider).tabIndex, 2);
    expect(container.read(provider).items.single.id, 'video');
    expect(container.read(provider).items.single.kind, 'video');

    // Completing the older novel request must not change the selected feed.
    requests[2]!.single.complete(
      HomepagePage(
        items: [_item('stale-book')],
        nextOffset: null,
        sessionId: null,
      ),
    );
    await _flushMicrotasks();
    expect(container.read(provider).tabIndex, 2);
    expect(container.read(provider).items.single.id, 'video');

    // The canceled novel request must not make an empty cache look loaded.
    notifier.selectTab(1);
    expect(requests[2], hasLength(2));
    requests[2]!.last.complete(
      HomepagePage(
        items: [_item('fresh-book')],
        nextOffset: null,
        sessionId: null,
      ),
    );
    await _flushMicrotasks();
    expect(container.read(provider).items.single.id, 'fresh-book');
    expect(container.read(provider).items.single.kind, 'book');
  });

  test('the home feed keeps the upstream corner badge', () async {
    // The 漫剧 tab is where the upstream ships badges, and it is also the tab
    // that rewrites every item's kind. The rewrite used to rebuild MediaItem by
    // hand and drop the badge, so nothing ever rendered on the home page.
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('manju-1', kind: 'manju', tag: _newTag)],
                  nextOffset: null,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
        manjuSearchLoader: ({int offset = 0}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await _loadTab(notifier, HomeNotifier.tabs.indexOf('漫剧'));

    final items = container.read(provider).items;
    expect(items, isNotEmpty);
    final tag = items.first.tag;
    expect(tag, isNotNull, reason: 'the kind rewrite must not drop the badge');
    expect(tag!.text, '上新');
    expect(tag.lightColors, ['#00B876', '#15D791']);
    expect(tag.darkColors, ['#009962', '#11B279']);
  });

  test(
    'the combined feed takes manju from its own stream, not search',
    () async {
      final manjuStreamOffsets = <int>[];
      final manjuSearchOffsets = <int>[];
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async {
                if (tabType != 24) {
                  return const HomepagePage(
                    items: [],
                    nextOffset: null,
                    sessionId: null,
                  );
                }
                manjuStreamOffsets.add(offset);
                return HomepagePage(
                  items: [_item('manju-stream', kind: 'manju', tag: _newTag)],
                  nextOffset: null,
                  sessionId: null,
                );
              },
          searchLoader: (query, {int page = 1}) async => [],
          mangaSearchLoader: ({int offset = 0}) async => [],
          manjuSearchLoader: ({int offset = 0}) async {
            manjuSearchOffsets.add(offset);
            return [
              SearchTab(
                title: '漫剧',
                items: [_item('manju-search-$offset', kind: 'manju')],
                hasMore: offset == 0,
                nextOffset: 17,
              ),
            ];
          },
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      await _loadTab(notifier, 0);

      // The stream serves the first screen; search is not consulted for it.
      expect(manjuStreamOffsets, [0]);
      expect(manjuSearchOffsets, isEmpty);
      expect(
        container.read(provider).items.map((i) => i.id),
        contains('manju-stream'),
      );
      // The badge from the stream survives into the combined feed.
      final streamed = container
          .read(provider)
          .items
          .firstWhere((i) => i.id == 'manju-stream');
      expect(streamed.tag?.text, '上新');

      // The 24 stream has no cursor, so paging continues through search.
      await notifier.loadMore();
      expect(manjuSearchOffsets, [0]);
      expect(
        container.read(provider).items.map((i) => i.id),
        contains('manju-search-0'),
      );
    },
  );

  test(
    'the combined feed falls back to manju search when the stream fails',
    () async {
      final manjuSearchOffsets = <int>[];
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async {
                if (tabType == 24) throw StateError('stream unavailable');
                return const HomepagePage(
                  items: [],
                  nextOffset: null,
                  sessionId: null,
                );
              },
          searchLoader: (query, {int page = 1}) async => [],
          mangaSearchLoader: ({int offset = 0}) async => [],
          manjuSearchLoader: ({int offset = 0}) async {
            manjuSearchOffsets.add(offset);
            return [
              SearchTab(
                title: '漫剧',
                items: [_item('manju-search', kind: 'manju')],
                hasMore: false,
                nextOffset: null,
              ),
            ];
          },
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      await _loadTab(notifier, 0);

      expect(manjuSearchOffsets, [0]);
      expect(
        container.read(provider).items.map((i) => i.id),
        contains('manju-search'),
      );
    },
  );

  group('server tab strip drives the tab identity', () {
    // 服务端 tab_item 有 11 项，与本地 7 项兜底表既不同长也不同序。按下标
    // 到本地表取名会把「经典」（服务端下标 2）解析成「短剧」，去拉
    // tab_type=8 —— 点经典看到短剧。
    const serverTabs = <HomeTabItem>[
      HomeTabItem(type: 2, title: '推荐'),
      HomeTabItem(type: 25, title: '小说'),
      HomeTabItem(type: 11, title: '经典'),
      HomeTabItem(type: 12, title: '知识'),
      HomeTabItem(type: 5, title: '听书'),
      HomeTabItem(type: 8, title: '看剧'),
      HomeTabItem(type: 16, title: '视频'),
      HomeTabItem(type: 103, title: '短篇'),
      HomeTabItem(type: 9, title: '漫画'),
      HomeTabItem(type: 31, title: '新书'),
      HomeTabItem(type: 15, title: '商城'),
    ];

    test(
      'a tab is requested with its own tab_type, not one from 本地表',
      () async {
        final requested = <int>[];
        final provider = NotifierProvider<HomeNotifier, HomeState>(
          () => HomeNotifier(
            homepageLoader:
                ({int tabType = 2, int offset = 0, String? sessionId}) async {
                  requested.add(tabType);
                  return HomepagePage(
                    items: [_item('book-$tabType')],
                    nextOffset: null,
                    sessionId: null,
                    tabs: serverTabs,
                  );
                },
            searchLoader: (query, {int page = 1}) async => [],
            mangaSearchLoader: ({int offset = 0}) async => [],
            manjuSearchLoader: ({int offset = 0}) async => [],
          ),
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(provider.notifier);
        // 首屏「推荐」= tab_type 2。
        await notifier.load();
        for (final index in [2, 3, 5, 8, 10]) {
          notifier.selectTab(index);
          await _flushMicrotasks();
        }

        // 每个下标的 tab_type 都来自它自己那一项：推荐 2、经典 11、知识 12、
        // 看剧 8、漫画 9、商城 15。若退回本地表则会是 2、24、5、16 —— 全部串台。
        expect(requested, [2, 11, 12, 8, 9, 15]);
      },
    );

    test(
      'the identity of a server tab keeps its kind and skips gender tabs',
      () async {
        final provider = NotifierProvider<HomeNotifier, HomeState>(
          () => HomeNotifier(
            homepageLoader:
                ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                    HomepagePage(
                      items: [_item('book-$tabType')],
                      nextOffset: null,
                      sessionId: null,
                      tabs: const [
                        HomeTabItem(type: 2, title: '推荐'),
                        HomeTabItem(type: 0, title: '女生'),
                        HomeTabItem(type: 9, title: '漫画'),
                      ],
                    ),
            searchLoader: (query, {int page = 1}) async => [],
            mangaSearchLoader: ({int offset = 0}) async => [],
            manjuSearchLoader: ({int offset = 0}) async => [],
          ),
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(provider.notifier);

        // 分类条还没回来时，下标只能按本地兜底表解释（首屏就是这样）。
        expect(notifier.identityOf(0), (
          name: '全部',
          kind: 'book',
          tabType: null,
        ));

        await notifier.load();

        expect(notifier.identityOf(0), (name: '推荐', kind: 'book', tabType: 2));
        // 0/1 是官方 female/male 入口，没有对应的书城流，只能走搜索兜底。
        expect(notifier.identityOf(1), (
          name: '女生',
          kind: 'book',
          tabType: null,
        ));
        expect(notifier.identityOf(2), (name: '漫画', kind: 'manga', tabType: 9));
      },
    );

    test('dramaProvider keeps reading the 本地表 even when tabs arrive', () async {
      // 短剧页的频道条是本地表下标拼的（dramaChannels）。它的 state.tabs 同样
      // 会被服务端那 11 项填满，若跟着服务端下标解析，它的「短剧」（本地 2）
      // 就会变成服务端的「经典」。
      final requested = <int>[];
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          initialTabIndex: HomeNotifier.tabs.indexOf('短剧'),
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async {
                requested.add(tabType);
                return HomepagePage(
                  items: [_item('book-$tabType')],
                  nextOffset: null,
                  sessionId: null,
                  tabs: serverTabs,
                );
              },
          searchLoader: (query, {int page = 1}) async => [],
          mangaSearchLoader: ({int offset = 0}) async => [],
          manjuSearchLoader: ({int offset = 0}) async => [],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);

      await notifier.load();

      // 本地表「短剧」= tab_type 8，不是服务端下标 2 的「经典」= 11。
      expect(requested, [8]);
      expect(notifier.identityOf(HomeNotifier.tabs.indexOf('短剧')), (
        name: '短剧',
        kind: 'video',
        tabType: 8,
      ));
    });
  });
}

Future<void> _loadTab(HomeNotifier notifier, int tabIndex) async {
  if (tabIndex == 0) {
    await notifier.load();
  } else {
    notifier.selectTab(tabIndex);
    await _flushMicrotasks();
  }
}

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

MediaItem _item(String id, {String kind = 'book', MediaTag? tag}) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
  tag: tag,
);

/// The upstream badge, as the home feed ships it.
const _newTag = MediaTag(
  text: '上新',
  lightColors: ['#00B876', '#15D791'],
  darkColors: ['#009962', '#11B279'],
);
