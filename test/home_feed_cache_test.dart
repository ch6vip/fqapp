import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/home_feed_cache.dart';
import 'package:hive_flutter/hive_flutter.dart';

MediaItem _item(String id, {String kind = 'video'}) => MediaItem(
  id: id,
  title: '剧 $id',
  cover: 'https://example.com/$id.jpg',
  author: '作者',
  badge: '12集',
  ep: '',
  kind: kind,
  tag: MediaTag(text: '爆款', lightColors: ['#FF0000']),
  intro: '简介 $id',
  followerCount: 7,
  categories: const ['都市'],
  episodeListText: '观看全集·12集',
);

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fqapp-home-feed-cache-test-',
    );
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    HomeFeedCache.hiveReady = false;
  });

  test('media item JSON round trip preserves every rendered field', () {
    final item = _item('a1');
    final restored = MediaItemJson.fromJson(item.toJson());
    expect(restored, isNotNull);
    expect(restored!.id, item.id);
    expect(restored.title, item.title);
    expect(restored.cover, item.cover);
    expect(restored.author, item.author);
    expect(restored.badge, item.badge);
    expect(restored.kind, item.kind);
    expect(restored.tag?.text, '爆款');
    expect(restored.tag!.colorsFor(dark: false), item.tag!.lightColors);
    expect(restored.tag?.hasColors, isTrue);
    expect(restored.intro, item.intro);
    expect(restored.followerCount, 7);
    expect(restored.categories, item.categories);
    expect(restored.episodeListText, item.episodeListText);
  });

  test('a truncated record cannot resurrect an item', () {
    expect(MediaItemJson.fromJson({'id': 'x', 'tag': 3}), isNull);
  });

  test('save then load returns the stored snapshot', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(2, [_item('a'), _item('b')], hasMore: true);
    final snapshot = cache.load(2);
    expect(snapshot, isNotNull);
    expect(snapshot!.items.map((item) => item.id), ['a', 'b']);
    expect(snapshot.hasMore, isTrue);
    expect(snapshot.lastVid, isNull);
    await cache.close();
  });

  test('lastVid round trips through save and load', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(1, [_item('a')], hasMore: true, lastVid: 'a');
    expect(cache.load(1)!.lastVid, 'a');
    // Empty strings and missing keys both restore as null.
    await cache.save(1, [_item('a')], hasMore: true, lastVid: '');
    expect(cache.load(1)!.lastVid, isNull);
    await cache.close();
  });

  test('load returns null before the box exists and after the TTL',
      () async {
    final cache = HomeFeedCache();
    expect(cache.load(0), isNull);

    HomeFeedCache.hiveReady = true;
    await cache.save(0, [_item('a')], hasMore: false);
    expect(cache.load(0), isNotNull);

    // Rewrite savedAt far into the past through the same box. Hive returns
    // the box singleton the cache already holds, so no reopen is needed.
    final box = await Hive.openBox('home_feed_cache_v1');
    final raw = Map<String, dynamic>.from(box.get('0') as Map);
    raw['savedAt'] =
        DateTime.now().millisecondsSinceEpoch -
        const Duration(days: 4).inMilliseconds;
    await box.put('0', raw);
    expect(cache.load(0), isNull);
    await cache.close();
  });

  test('cold start renders the cached feed while the refresh is in flight',
      () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(0, [_item('cached-1'), _item('cached-2')], hasMore: true);

    final networkStarted = Completer<void>();
    final releaseNetwork = Completer<void>();
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async {
          networkStarted.complete();
          await releaseNetwork.future;
          return HomepagePage(
            items: [_item('fresh-1', kind: 'book')],
            nextOffset: 1,
            sessionId: null,
          );
        },
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    final loading = notifier.load();

    // Before the network answers, the snapshot is already on screen.
    expect(
      container.read(provider).items.map((item) => item.id),
      ['cached-1', 'cached-2'],
    );
    expect(container.read(provider).isLoading, isTrue);

    releaseNetwork.complete();
    await loading;
    expect(
      container.read(provider).items.map((item) => item.id),
      ['fresh-1'],
    );
  });

  test('a failed refresh keeps the cached feed visible with the error',
      () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(3, [_item('kept')], hasMore: true);

    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: 3,
        homepageLoader:
            ({
              int tabType = 2,
              int offset = 0,
              String? sessionId,
            }) async => throw StateError('offline'),
        searchLoader:
            (query, {int page = 1}) async => throw StateError('offline'),
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await notifier.load();
    await _flushMicrotasks();
    final state = container.read(provider);
    expect(state.error, isNotNull);
    expect(state.items.map((item) => item.id), ['kept']);
  });

  test('a resumed cold start appends the fresh feed after the resume card',
      () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(
      6,
      [_item('old-1'), _item('last'), _item('old-3')],
      hasMore: true,
      lastVid: 'last',
    );

    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: 6,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  // 'last' reappears in the response: the seen set must
                  // deduplicate it (the client-side equivalent of the
                  // official filterIds request parameter).
                  items: [_item('fresh-1'), _item('last'), _item('fresh-2')],
                  nextOffset: 1,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    final loading = notifier.load();

    // The visible list starts AT the resume card: earlier snapshot cards are
    // dropped, matching the official single-video landing cache.
    expect(
      container.read(provider).items.map((item) => item.id),
      ['last', 'old-3'],
    );

    await loading;
    // The fresh list is appended after the visible card, never replacing it —
    // the on-screen video must not flip to a different one.
    expect(
      container.read(provider).items.map((item) => item.id),
      ['last', 'old-3', 'fresh-1', 'fresh-2'],
    );
  });

  test('a resume card already at index zero still appends instead of '
      'replacing', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(
      6,
      [_item('last'), _item('old-2')],
      hasMore: true,
      lastVid: 'last',
    );

    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: 6,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('fresh-1')],
                  nextOffset: 1,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await notifier.load();
    expect(
      container.read(provider).items.map((item) => item.id),
      ['last', 'old-2', 'fresh-1'],
    );
  });

  test('a resume point outside the snapshot falls back to wholesale replace',
      () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(6, [_item('a'), _item('b')], hasMore: true,
        lastVid: 'gone');

    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: 6,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('fresh-1')],
                  nextOffset: 1,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await notifier.load();
    expect(
      container.read(provider).items.map((item) => item.id),
      ['fresh-1'],
    );
  });

  test('a manual refresh replaces the list instead of resuming', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(6, [_item('a'), _item('b')], hasMore: true,
        lastVid: 'b');

    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: 6,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('fresh-1')],
                  nextOffset: 1,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await notifier.load(manualRefresh: true);
    // Official Refresh path: the response replaces page one wholesale.
    expect(
      container.read(provider).items.map((item) => item.id),
      ['fresh-1'],
    );
  });

  test('the position reported by the page is persisted as the resume point',
      () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: 6,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('fresh-1'), _item('fresh-2')],
                  nextOffset: 1,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    notifier.noteCurrentVid('fresh-2');
    await notifier.load();
    // The save is fire-and-forget file IO; give the event loop real time.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(cache.load(6)!.lastVid, 'fresh-2');
    await cache.close();
  });
}
