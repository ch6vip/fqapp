import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';

void main() {
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

MediaItem _item(String id, {String kind = 'book'}) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
);
