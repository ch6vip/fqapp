import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';

void main() {
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

  for (final failedOffset in [0, 17]) {
    test(
      'combined feed retries manga at $failedOffset and resets exhaustion on refresh',
      () async {
        final offsets = <int>[];
        var failed = false;
        final provider = NotifierProvider<HomeNotifier, HomeState>(
          () => HomeNotifier(
            homepageLoader:
                ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                    HomepagePage(
                      items: [_item('book-$offset')],
                      nextOffset: offset + 1,
                      sessionId: null,
                    ),
            searchLoader: (query, {int page = 1}) async => [],
            mangaSearchLoader: ({int offset = 0}) async {
              offsets.add(offset);
              if (offset == failedOffset && !failed) {
                failed = true;
                throw StateError('temporary outage');
              }
              return [
                SearchTab(
                  title: '漫画',
                  items: [_item('manga-$offset', kind: 'manga')],
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
        await notifier.load();
        for (var i = 0; i < 4; i++) {
          await notifier.loadMore();
        }
        expect(offsets, failedOffset == 0 ? [0, 0, 17] : [0, 17, 17]);
        expect(
          container
              .read(provider)
              .items
              .where((item) => item.kind == 'manga')
              .map((item) => item.id),
          ['manga-0', 'manga-17'],
        );
        await notifier.load();
        await notifier.loadMore();
        expect(offsets.sublist(offsets.length - 2), [0, 17]);
      },
    );
  }

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

  for (final failedOffset in [0, 17]) {
    test(
      'combined feed retries manju cursor $failedOffset and remembers exhaustion',
      () async {
        final offsets = <int>[];
        var failed = false;
        final provider = NotifierProvider<HomeNotifier, HomeState>(
          () => HomeNotifier(
            homepageLoader:
                ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                    HomepagePage(
                      items: [_item('book-$offset')],
                      nextOffset: offset + 1,
                      sessionId: null,
                    ),
            searchLoader: (query, {int page = 1}) async => [],
            manjuSearchLoader: ({int offset = 0}) async {
              offsets.add(offset);
              if (offset == failedOffset && !failed) {
                failed = true;
                throw StateError('temporary failure');
              }
              return [
                SearchTab(
                  title: '短剧',
                  items: [_item('manju-$offset', kind: 'manju')],
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
        await notifier.load();
        for (var page = 0; page < 4; page++) {
          await notifier.loadMore();
        }
        expect(offsets, failedOffset == 0 ? [0, 0, 17] : [0, 17, 17]);
        expect(
          container
              .read(provider)
              .items
              .where((item) => item.kind == 'manju')
              .map((item) => item.id),
          ['manju-0', 'manju-17'],
        );
        expect(container.read(provider).hasMore, isTrue);
        await notifier.load();
        await notifier.loadMore();
        expect(offsets.sublist(offsets.length - 2), [0, 17]);
      },
    );
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
    'a failed category does not skip its page in the combined feed',
    () async {
      final videoRequests = <int>[];
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                  HomepagePage(
                    items: [_item('novel-$offset')],
                    nextOffset: offset + 1,
                    sessionId: null,
                  ),
          searchLoader: (query, {int page = 1}) async {
            if (query != '短剧') return [];
            videoRequests.add(page);
            if (videoRequests.length == 1) {
              throw StateError('temporary failure');
            }
            return [
              SearchTab(
                title: '短剧',
                items: [_item('video-$page', kind: 'video')],
              ),
            ];
          },
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      await notifier.load();
      await notifier.loadMore();
      expect(videoRequests, [1, 1]);
      expect(
        container.read(provider).items.map((item) => item.id),
        contains('video-1'),
      );
    },
  );

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

  test('the combined feed keeps badges from every source', () async {
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('book-1', tag: _newTag)],
                  nextOffset: null,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [
          SearchTab(
            title: query,
            items: [_item('$query-1', kind: 'video', tag: _newTag)],
          ),
        ],
        mangaSearchLoader: ({int offset = 0}) async => [],
        manjuSearchLoader: ({int offset = 0}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await _loadTab(notifier, 0);

    final items = container.read(provider).items;
    expect(items, isNotEmpty);
    for (final item in items) {
      expect(
        item.tag?.text,
        '上新',
        reason: '${item.id} (${item.kind}) lost its badge',
      );
    }
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
