import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'package:fqapp/services/digg_store.dart';
import 'support/controlled_player.dart';
MediaItem _item(String label, {String kind = 'video', String ep = ''}) =>
    MediaItem(
      id: label,
      title: '$label 作品',
      cover: '',
      author: '演员',
      badge: '',
      ep: ep,
      kind: kind,
    );

/// A notifier whose stream answers with `perTab` items per tab_type, so a test
/// can tell which channel a feed is actually reading. The drama tab's override
/// has to open on the 短剧 channel the way the real `dramaProvider` does.
HomeNotifier _notifier({int perTab = 1, int initialTabIndex = 0}) => HomeNotifier(
  initialTabIndex: initialTabIndex,
  homepageLoader: ({int tabType = 2, int offset = 0, String? sessionId}) async {
    return HomepagePage(
      items: [
        for (var index = 0; index < perTab; index++)
          _item('$tabType-$index', ep: index == 0 ? '全12集' : ''),
      ],
      nextOffset: null,
      sessionId: null,
    );
  },
  searchLoader: (query, {int page = 1}) async => const [],
);

/// Both feeds are faked together: the shell mounts the home page next to the
/// 短剧 destination, and the drama page reads only the second provider.
ProviderScope _scope({required Widget child, int perTab = 1}) => ProviderScope(
  overrides: [
    homeProvider.overrideWith(() => _notifier(perTab: perTab)),
    dramaProvider.overrideWith(
      () => _notifier(perTab: perTab, initialTabIndex: dramaTabIndex),
    ),
  ],
  child: child,
);

ProviderContainer _container({int perTab = 1}) => ProviderContainer(
  overrides: [
    homeProvider.overrideWith(() => _notifier(perTab: perTab)),
    dramaProvider.overrideWith(
      () => _notifier(perTab: perTab, initialTabIndex: dramaTabIndex),
    ),
  ],
);

/// The drama feed is a vertical pager; one drag moves it exactly one page.
Future<void> _swipeUp(WidgetTester tester) async {
  await tester.drag(find.byKey(const Key('drama_feed')), const Offset(0, -600));
  await tester.pumpAndSettle();
}

/// The feed now plays the on-screen card inline, so every case injects a fake
/// player and an address loader: a case that is not about inline playback must
/// neither reach the real backend nor allocate a real native player.
class _Seams {
  _Seams({this.failContent = true});

  /// Whether the injected address loader refuses, which is the cheapest way to
  /// keep a card from creating a player.
  final bool failContent;
  final players = <ControlledNativePlayer>[];
  final contentCalls = <String>[];
  final store = ControlledReaderStore();

  DramaPage page({
    Future<List<List<Chapter>>> Function(String id, String tab)?
    directoryLoader,
    Widget Function()? searchPageBuilder,
  }) => DramaPage(
    directoryLoader: directoryLoader,
    contentLoader: (itemId, tab) async {
      contentCalls.add('$itemId:$tab');
      if (failContent) throw const ApiException('内联取址不可用');
      return {'video_url': 'https://example.invalid/$itemId.mp4'};
    },
    historyStore: store,
    playerFactory: () {
      final player = ControlledNativePlayer();
      players.add(player);
      return player;
    },
    searchPageBuilder: searchPageBuilder,
  );
}

/// Bounded flushing: never `pumpAndSettle` on a loading indicator.
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

late Directory _hiveDir;

void main() {
  // The follow button writes the local shelf, so the box has to exist before a
  // test taps it. Opening it in setUp keeps that I/O out of the fake-async zone
  // the test bodies run in (see the bookshelf note's testing lesson).
  setUp(() async {
    _hiveDir = await Directory.systemTemp.createTemp('fqapp-drama-test-');
    Hive.init(_hiveDir.path);
    await ShelfStore.instance.init();
    // 点赞 与 追剧 一样落在本地 box，测试点它之前必须先开箱。
    await DiggStore.instance.init();
  });

  tearDown(() async {
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await _hiveDir.delete(recursive: true);
    } catch (_) {
      // Temp dirs live under the system temp folder; a failed cleanup is noise.
    }
  });

  testWidgets('点赞 落进本地 digg box 并立刻把按钮变成 已赞', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(perTab: 1, child: MaterialApp(home: _Seams().page())),
    );
    await _flush(tester);
    expect(find.text('点赞'), findsOneWidget);
    expect(find.text('已赞'), findsNothing);
    expect(DiggStore.instance.containsItem(_item('8-0')), isFalse);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('drama_like_button')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await _flush(tester);

    // 官方的成功文案 `@string/bzl`=「点赞成功，可在「我的-我的点赞」查看」。
    expect(DiggStore.instance.containsItem(_item('8-0')), isTrue);
    expect(find.text('已赞'), findsOneWidget);
    expect(find.text('点赞'), findsNothing);
    expect(find.textContaining('点赞成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the channel strip is the official five, with their real tab types', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(homeProvider).tabIndex, 0);
    expect(container.read(dramaProvider).tabIndex, dramaTabIndex);
    expect(
      dramaChannels.map((channel) => channel.label),
      ['推荐', '看剧', '漫剧', '最近', '收藏'],
    );
    // 推荐 = BookstoreTabType.video_feed(16), 看剧 = video_episode(8),
    // 漫剧 = dynamic_comic(24); the last two are device-local lists.
    expect(
      HomeNotifier.tabTypes[HomeNotifier.tabs[dramaChannels[0].tabIndex]],
      16,
    );
    expect(dramaChannels[1].tabIndex, dramaTabIndex);
    expect(dramaChannels[1].kind, 'video');
    expect(
      HomeNotifier.tabTypes[HomeNotifier.tabs[dramaChannels[2].tabIndex]],
      24,
    );
    expect(dramaChannels[2].kind, 'manju');
    expect(dramaChannels[3].source, DramaChannelSource.history);
    expect(dramaChannels[4].source, DramaChannelSource.shelf);
    // 预约 has no data source and is deliberately absent.
    expect(dramaChannels.map((channel) => channel.label), isNot(contains('预约')));
  });

  test('the drama feed keeps its own cursor when the home page switches', () async {
    final container = _container();
    addTearDown(container.dispose);

    await container.read(dramaProvider.notifier).load();
    await container.read(homeProvider.notifier).load();
    final dramaItems = container.read(dramaProvider).items;
    expect(dramaItems, isNotEmpty);
    expect(dramaItems.every((item) => item.kind == 'video'), isTrue);

    container.read(homeProvider.notifier).selectTab(5); // 听书 supersedes it.
    await Future<void>.delayed(Duration.zero);

    expect(container.read(dramaProvider).tabIndex, dramaTabIndex);
    expect(container.read(dramaProvider).items, same(dramaItems));
    expect(container.read(homeProvider).items.first.id, startsWith('5-'));
  });

  testWidgets('the feed shows the official chrome and one full-screen card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(
        perTab: 4,
        child: MaterialApp(home: _Seams().page()),
      ),
    );
    await _flush(tester);


    // Top bar: the official search hint and the channel strip.
    expect(find.text('请输入短剧名或主演名'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('漫剧'), findsOneWidget);
    expect(find.byKey(const Key('drama_search_button')), findsOneWidget);
    // 官方 `ap3.xml` 的 `@id/h4f` 是 20dp **搜索**按钮（`Xh()` → `mh()`
    // 「点击新按钮 从书城进如搜索页」），不是刷新按钮。刷新在官方是下拉手势。
    expect(find.byKey(const Key('drama_strip_search_button')), findsOneWidget);

    // One card, filling the page, with the official chrome: the right rail's
    // 追剧 + 点赞 and the bottom info line. The three self-invented pills
    // (观看完整短剧 / 查看剧集) are gone — the official card carries no buttons
    // along its bottom edge (`cjq.xml` puts 追剧 in the right rail).
    expect(find.byKey(const Key('drama_feed')), findsOneWidget);
    expect(find.text('8-0 作品'), findsOneWidget);
    expect(find.byKey(const Key('drama_follow_button')), findsOneWidget);
    expect(find.text('追剧'), findsOneWidget);
    expect(find.byKey(const Key('drama_like_button')), findsOneWidget);
    expect(find.text('观看完整短剧'), findsNothing);
    expect(find.text('查看剧集'), findsNothing);
    expect(find.text('全屏观看'), findsOneWidget);
    // 官方 feed 的上滑提示是 `@string/eal`=「上滑查看更多视频」（14sp，底 #CC222222，
    // 距底 94dp，1s 后消失）；`上滑继续观看短剧`(`@string/e6j`) 属播放页 BottomContainer。
    expect(find.text('上滑查看更多视频'), findsOneWidget);
    expect(find.text('8-1 作品'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('上滑查看更多视频'), findsNothing);
    expect(tester.takeException(), isNull);

  });

  testWidgets('swiping up reveals the next drama and switching channels swaps the feed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(perTab: 4, child: MaterialApp(home: _Seams().page())),
    );
    await tester.pumpAndSettle();
    expect(find.text('8-0 作品'), findsOneWidget);

    await _swipeUp(tester);
    expect(find.text('8-0 作品'), findsNothing);
    expect(find.text('8-1 作品'), findsOneWidget);

    // 看剧 is the official name for tab_type=8, the feed this page shows by
    // default; 漫剧 keeps its own cursor behind it.
    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    expect(find.text('24-0 作品'), findsOneWidget);
    expect(find.text('8-1 作品'), findsNothing);

    await tester.tap(find.text('看剧'));
    await tester.pumpAndSettle();
    expect(find.text('8-0 作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed feed shows the official error copy and retries', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    var failing = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dramaProvider.overrideWith(
            () => HomeNotifier(
              initialTabIndex: dramaTabIndex,
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    if (failing) throw ApiException('短剧服务暂时不可用');
                    return const HomepagePage(
                      items: [],
                      nextOffset: null,
                      sessionId: null,
                    );
                  },
              // The stream outage falls back to search, so both must fail for
              // the page to reach its error state.
              searchLoader: (query, {int page = 1}) async {
                if (failing) throw ApiException('短剧服务暂时不可用');
                return const [];
              },
            ),
          ),
        ],
        child: MaterialApp(home: _Seams().page()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('网络异常，请稍后再试'), findsOneWidget);
    expect(find.text('点击重试'), findsOneWidget);

    failing = false;
    await tester.tap(find.text('点击重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂无符合条件的短剧'), findsOneWidget);
    expect(find.text('网络异常，请稍后再试'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏观看 loads the series directory before playing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    final pending = Completer<List<List<Chapter>>>();
    final calls = <String>[];
    // Inline playback is live here, so this is also the handover regression:
    // the card's player must be gone before the directory is fetched.
    final seams = _Seams(failContent: false);
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: seams.page(
            directoryLoader: (id, tab) {
              calls.add('$id:$tab');
              // The inline session's own directory request answers; the one the
              // tap starts is held so the loading overlay stays observable.
              if (calls.length == 1) {
                return Future.value([
                  [Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集')],
                ]);
              }
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(seams.players, hasLength(1));
    final inline = seams.players.single;
    expect(inline.isPlaying, isTrue);

    // 官方只有「全屏观看」(`mq3.e` / `aqi.xml`) 会进全页播放器；点画面中间
    // 只切换播放/暂停（见下一条用例）。
    await tester.tap(find.byKey(const Key('drama_fullscreen_button')));
    // The push waits for the inline release before the directory request, so
    // the second request is only recorded after the player is gone.
    await _flush(tester);
    expect(calls, ['8-0:短剧', '8-0:短剧']);
    expect(inline.disposed, isTrue);
    expect(find.text('视频加载中，请稍后'), findsOneWidget);

    pending.completeError(const ApiException('剧集列表暂时无法加载'));
    await tester.pumpAndSettle();
    expect(find.textContaining('剧集列表暂时无法加载'), findsOneWidget);
    expect(find.text('视频加载中，请稍后'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单击画面只切换播放/暂停，不进任何页面', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    final seams = _Seams(failContent: false);
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: seams.page(
            // The inline session needs a directory before it can create a
            // player; the real client would reach the backend.
            directoryLoader: (id, tab) async => [
              [Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集')],
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(seams.players, hasLength(1));
    final inline = seams.players.single;
    expect(inline.isPlaying, isTrue);

    // 已经没有双击手势了，单击立即派发。
    await tester.tap(find.byKey(const ValueKey('drama_card_video_8-0')));
    await _flush(tester);


    // 暂停：播放器还在，但不再播放；没有 push、没有目录请求。
    expect(inline.disposed, isFalse);
    expect(inline.isPlaying, isFalse);
    expect(inline.calls, contains('pause'));
    expect(seams.contentCalls, ['8-0-1:短剧']);
    expect(find.text('视频加载中，请稍后'), findsNothing);

    // 再点一次继续播放。
    await tester.tap(find.byKey(const ValueKey('drama_card_video_8-0')));
    await _flush(tester);
    expect(inline.isPlaying, isTrue);
    expect(inline.disposed, isFalse);
    expect(tester.takeException(), isNull);
  });


  testWidgets('追剧 落进本地书架并立刻把按钮变成 已追剧', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(perTab: 1, child: MaterialApp(home: _Seams().page())),
    );
    await tester.pumpAndSettle();
    expect(find.text('追剧'), findsOneWidget);
    expect(find.text('已追剧'), findsNothing);
    expect(ShelfStore.instance.records(), isEmpty);

    // The tap starts a Hive write inside the page, so it has to run in the real
    // async zone for the write (and the store's notification) to complete.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('drama_follow_button')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(ShelfStore.instance.records().map((r) => r.item.id), ['8-0']);
    expect(find.text('已追剧'), findsOneWidget);
    expect(find.text('追剧'), findsNothing);
    expect(find.textContaining('已追剧，可在「书架-短剧」查看'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bottom bar lists 短剧 right after 首页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(
        child: MaterialApp(home: RootShell(backendStarter: () async {})),
      ),
    );
    await tester.pumpAndSettle();

    // Scoped to the bar: the home page's own category strip also has a 短剧 entry.
    Finder navLabel(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

    final home = tester.getCenter(navLabel('首页')).dx;
    final drama = tester.getCenter(navLabel('短剧')).dx;
    final library = tester.getCenter(navLabel('书架')).dx;
    final mine = tester.getCenter(navLabel('我的')).dx;
    expect(home, lessThan(drama));
    expect(drama, lessThan(library));
    expect(library, lessThan(mine));

    // The destination is lazy: nothing of the 短剧 feed is built before a tap.
    expect(find.byType(DramaPage), findsNothing);
    await tester.tap(navLabel('短剧'));
    await tester.pumpAndSettle();
    expect(find.byType(DramaPage), findsOneWidget);
    expect(find.byKey(const Key('drama_feed')), findsOneWidget);
    // 右侧栏的 追剧 取代了原先那排自创药丸按钮。
    expect(find.text('追剧'), findsOneWidget);
    // The shell mounts its own DramaPage without seams, so its inline session
    // starts a real directory request here. Advance past the client timeout to
    // drain that timer, which would otherwise outlive the test.
    await tester.pump(const Duration(seconds: 25));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
