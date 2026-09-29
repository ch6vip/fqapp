import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive/hive.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/models/channel_tab.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/swipe_guide_store.dart';

import 'package:fqapp/services/digg_store.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';
import 'support/controlled_player.dart';

MediaItem _item(
  String label, {
  String kind = 'video',
  String ep = '',
  String intro = '',
  int followerCount = 0,
  List<String> categories = const [],
}) => MediaItem(
  id: label,
  title: '$label 作品',
  cover: '',
  author: '演员',
  badge: '',
  ep: ep,
  kind: kind,
  intro: intro,
  followerCount: followerCount,
  categories: categories,
);

/// A notifier whose stream answers with `perTab` items per tab_type, so a test
/// can tell which channel a feed is actually reading. The drama tab's override
/// has to open on the 短剧 channel the way the real `dramaProvider` does.
/// [intro]/[followerCount]/[categories] decorate the first card so the info
/// panel cases can exercise the chips, the intro and the removed rail count.
HomeNotifier _notifier({
  int perTab = 1,
  int initialTabIndex = 0,
  String intro = '',
  int followerCount = 0,
  List<String> categories = const [],
}) => HomeNotifier(
  initialTabIndex: initialTabIndex,
  homepageLoader: ({int tabType = 2, int offset = 0, String? sessionId}) async {
    return HomepagePage(
      items: [
        for (var index = 0; index < perTab; index++)
          _item(
            '$tabType-$index',
            ep: index == 0 ? '全12集' : '',
            intro: index == 0 ? intro : '',
            followerCount: index == 0 ? followerCount : 0,
            categories: index == 0 ? categories : const [],
          ),
      ],
      nextOffset: null,
      sessionId: null,
    );
  },
  searchLoader: (query, {int page = 1}) async => const [],
);

/// Both feeds are faked together: the shell mounts the home page next to the
/// 短剧 destination, and the drama page reads only the second provider.
ProviderScope _scope({
  required Widget child,
  int perTab = 1,
  String intro = '',
  int followerCount = 0,
  List<String> categories = const [],
}) => ProviderScope(
  overrides: [
    homeProvider.overrideWith(
      () => _notifier(
        perTab: perTab,
        intro: intro,
        followerCount: followerCount,
        categories: categories,
      ),
    ),
    dramaProvider.overrideWith(
      () => _notifier(
        perTab: perTab,
        initialTabIndex: dramaTabIndex,
        intro: intro,
        followerCount: followerCount,
        categories: categories,
      ),
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
    Future<ChannelTable> Function()? channelLoader,
    Future<SeriesDetail> Function(String seriesId)? seriesDetailLoader,
    Future<PlayletCommentPage> Function(String seriesId)? seriesCommentLoader,
  }) => DramaPage(
    directoryLoader: directoryLoader,
    channelLoader: channelLoader,
    seriesDetailLoader: seriesDetailLoader,
    seriesCommentLoader: seriesCommentLoader,
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
  // 本地列表和播放回归共用存储；开箱 I/O 保持在 fake-async 区外。
  setUp(() async {
    _hiveDir = await Directory.systemTemp.createTemp('fqapp-drama-test-');
    Hive.init(_hiveDir.path);
    // 生产 config.json 发新底栏（use_new_player_bottom_style=true）；测试
    // 默认值是旧栏，而旧栏在 o.W7() 下进页即清屏，会压掉播放页右栏断言。
    PlayerStyleConfig.instance = const PlayerStyleConfig(
      useNewPlayerBottomStyle: true,
    );
    await ShelfStore.instance.init();
    // 核对短剧手势不会再写入本机点赞。
    await DiggStore.instance.init();
    // 「上滑查看更多视频」引导带 8s 定时器：默认按「已显示过」处理，
    // 否则所有用例结束时都会留下 pending timer；引导自身的用例再 reset。
    await SwipeGuideStore.instance.init();
    await SwipeGuideStore.instance.markShown();
  });

  tearDown(() async {
    PlayerStyleConfig.instance = PlayerStyleConfig.defaults;
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

  testWidgets('短剧频道与完整播放页移除追剧点赞分享，播放与选集仍可用', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const nativeChannel = MethodChannel('fqapp/native_player');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      nativeChannel,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final seams = _Seams(failContent: false);
    await tester.pumpWidget(
      _scope(
        followerCount: 1200,
        child: MaterialApp(
          home: seams.page(
            directoryLoader: (id, tab) async => [
              [Chapter(itemId: '$id-1', title: '第1集', volumeName: '剧集')],
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drama_follow_button')), findsNothing);
    expect(find.byKey(const Key('drama_like_button')), findsNothing);
    expect(find.text('追剧'), findsNothing);
    expect(find.text('点赞'), findsNothing);
    await tester.tap(find.byKey(const Key('drama_episode_pill')));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    expect(find.byType(PlayerPage), findsOneWidget);
    VideoPlayerChrome chrome() =>
        tester.widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome));
    for (var attempt = 0; attempt < 30 && !chrome().enabled; attempt++) {
      await _flush(tester);
    }
    expect(chrome().enabled, isTrue);
    for (final key in [
      'player-follow-button',
      'player-like-button',
      'player-share-button',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
    expect(find.byKey(const ValueKey('player-comment-button')), findsOneWidget);
    final player = seams.players.last;
    player.calls.clear();
    final surface = tester.getCenter(
      find.byKey(const ValueKey('video-surface')),
    );
    for (var gesture = 0; gesture < 2; gesture++) {
      await tester.tapAt(surface);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(surface);
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.byKey(const ValueKey('player-like-animation')), findsNothing);
    expect(DiggStore.instance.containsItem(_item('8-0')), isFalse);
    expect(ShelfStore.instance.containsItem(_item('8-0')), isFalse);
    expect(player.calls.where((call) => call == 'pause'), isEmpty);
    await tester.pump(const Duration(milliseconds: 900));
    await tester.tapAt(surface);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), hasLength(1));
    await tester.tap(find.byKey(const ValueKey('player-catalog-bar')));
    // sheet 在首帧布局后才启动 200ms 动画，再推进两帧让惰性格子挂载。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('story-episode-0')).hitTestable(),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('story-panel-collect')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
  });

  test('the channel strip is the official five, with their real tab types', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(homeProvider).tabIndex, 0);
    expect(container.read(dramaProvider).tabIndex, dramaTabIndex);
    expect(dramaChannels.map((channel) => channel.label), [
      '推荐',
      '看剧',
      '漫剧',
      '最近',
      '收藏',
    ]);
    // 推荐 = BookstoreTabType.video_feed(16), 看剧 = video_episode(8),
    // 漫剧 = dynamic_comic(24); the last two are device-local lists.
    // （预约=video_subscribe 28 无数据源，刻意不做。）
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
  });

  test(
    'the drama feed keeps its own cursor when the home page switches',
    () async {
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
    },
  );

  testWidgets('the feed shows the official chrome and one full-screen card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    // 本用例要看到引导，先把 setUp 置上的「已显示」清掉（Hive 写走真实异步区）。
    await tester.runAsync(SwipeGuideStore.instance.reset);

    await tester.pumpWidget(
      _scope(perTab: 4, child: MaterialApp(home: _Seams().page())),
    );
    await _flush(tester);

    // Top bar: the official search hint and the channel strip (官方六个频道，
    // 顺序同截图；顶栏按 `ap4.xml` 根背景 @null 透明压在视频流上)。
    expect(find.text('请输入短剧名或主演名'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('漫剧'), findsOneWidget);
    expect(find.byKey(const Key('drama_search_button')), findsOneWidget);
    // 官方 `ap3.xml` 的 `@id/h4f` 是 20dp **搜索**按钮（`Xh()` → `mh()`
    // 「点击新按钮 从书城进如搜索页」），不是刷新按钮。刷新在官方是下拉手势。
    expect(find.byKey(const Key('drama_strip_search_button')), findsOneWidget);

    // 全屏卡片保留底部观看与信息入口，用户移除了右侧追剧、点赞栏。
    expect(find.byKey(const Key('drama_feed')), findsOneWidget);
    // 默认频道是推荐（tab_type 16）：首帧加载的就是 16 的流，不再先打
    // provider 初始的短剧 tab（8）再被频道表整换。
    expect(find.text('16-0 作品'), findsOneWidget);
    expect(find.byKey(const Key('drama_follow_button')), findsNothing);
    expect(find.text('追剧'), findsNothing);
    expect(find.byKey(const Key('drama_like_button')), findsNothing);
    expect(find.text('观看完整短剧'), findsNothing);
    expect(find.text('查看剧集'), findsNothing);
    // 官方卡片底部唯一的一颗按钮是居中的「观看全集」药丸（`ad9.xml`，文案
    // `nk3.c.d()` 用集数填）。夹具的 ep='全12集' 不是纯数字，按官方 ≤1 的
    // 分支退到 `@string/e7w`=「观看全片」。圆形全屏钮只在横版解码尺寸下出现。
    expect(find.byKey(const Key('drama_episode_pill')), findsOneWidget);
    expect(find.text('观看全片'), findsOneWidget);
    expect(find.byKey(const Key('drama_fullscreen_button')), findsNothing);
    // 官方 feed 的上滑提示是 `@string/eal`=「上滑查看更多视频」（14sp，底 #CC222222，
    // 距底 94dp）。官方 `pp3.f` 是 300ms 淡入后 **8 次 1s 计数**才淡出
    // （第二轮笔记的「1s 后消失」是误读），且每台设备只弹一次。
    expect(find.text('上滑查看更多视频'), findsOneWidget);
    expect(find.text('16-1 作品'), findsNothing);
    // 8 秒内一直在。
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('上滑查看更多视频'), findsOneWidget);
    // 计满 8s（从 300ms 淡入结束起算）后 300ms 淡出、再从树上摘掉：
    // 挂载在 8.3s 结束，这里泵到 8.7s。
    await tester.pump(const Duration(seconds: 3, milliseconds: 700));
    expect(find.text('上滑查看更多视频'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('上滑引导换频道立即收起，且每台设备只弹一次', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    // 官方 `wp3.d0`：SharedPreferences 标记一旦写回就再也不弹。setUp 已把
    // 标记置真，先清掉模拟「首次安装」。Hive 写在假时钟区里永远不完成
    // 写入必须走 runAsync 的真实异步区。
    await tester.runAsync(SwipeGuideStore.instance.reset);
    expect(SwipeGuideStore.instance.shown, isFalse);

    await tester.pumpWidget(
      _scope(perTab: 1, child: MaterialApp(home: _Seams().page())),
    );
    await tester.pump();
    expect(find.text('上滑查看更多视频'), findsOneWidget);
    expect(SwipeGuideStore.instance.shown, isTrue);

    // 官方横向频道 pager 一滚动就收（`onPageScrolled` → `pp3.f.m()`）；
    // 这里等价于点频道。300ms 淡出后从树上摘掉。
    await tester.tap(find.text('看剧'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('上滑查看更多视频'), findsNothing);

    // 回到推荐频道也不再弹（标记已写回）。
    await tester.tap(find.text('推荐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('上滑查看更多视频'), findsNothing);
    // 冲刷页面里 markShown 留下的真实异步写，别把它带进 tearDown 的 Hive.close。
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(tester.takeException(), isNull);
  });

  testWidgets('上滑引导已显示过就不再出现', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(perTab: 1, child: MaterialApp(home: _Seams().page())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('上滑查看更多视频'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'swiping up reveals the next drama and switching channels swaps the feed',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pumpWidget(
        _scope(perTab: 4, child: MaterialApp(home: _Seams().page())),
      );
      await tester.pumpAndSettle();
      // 推荐频道 = tab_type 16 的流；看剧才是 8（tabIndex=2）。
      expect(find.text('16-0 作品'), findsOneWidget);

      await _swipeUp(tester);
      expect(find.text('16-0 作品'), findsNothing);
      expect(find.text('16-1 作品'), findsOneWidget);

      // 看剧 is the official name for tab_type=8, the feed this page shows by
      // default; 漫剧 keeps its own cursor behind it.
      await tester.tap(find.text('漫剧'));
      await tester.pumpAndSettle();
      expect(find.text('24-0 作品'), findsOneWidget);
      expect(find.text('16-1 作品'), findsNothing);

      await tester.tap(find.text('看剧'));
      await tester.pumpAndSettle();
      expect(find.text('8-0 作品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets('全屏观看 loads the series directory before playing', (tester) async {
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

    // 官方进全页播放器的入口是「观看全集」药丸（`nk3.c.e` 的
    // 「watch_full_episodes」）；点画面中间只切换播放/暂停（见下一条用例）。
    await tester.tap(find.byKey(const Key('drama_episode_pill')));
    // The push waits for the inline release before the directory request, so
    // the second request is only recorded after the player is gone.
    await _flush(tester);
    expect(calls, ['16-0:短剧', '16-0:短剧']);
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
    await tester.tap(find.byKey(const ValueKey('drama_card_video_16-0')));
    await _flush(tester);

    // 暂停：播放器还在，但不再播放；没有 push、没有目录请求。
    expect(inline.disposed, isFalse);
    expect(inline.isPlaying, isFalse);
    expect(inline.calls, contains('pause'));
    expect(seams.contentCalls, ['16-0-1:短剧']);
    expect(find.text('视频加载中，请稍后'), findsNothing);

    // 再点一次继续播放。
    await tester.tap(find.byKey(const ValueKey('drama_card_video_16-0')));
    await _flush(tester);
    expect(inline.isPlaying, isTrue);
    expect(inline.disposed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('信息面板：药丸按集数出文案，chip 与简介可展开', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(
        perTab: 1,
        intro: '一个长生却会老的穿越者的故事简介，足够长到需要截断才能看到展开按钮',
        followerCount: 46000,
        categories: const ['喜剧'],
        child: MaterialApp(home: _Seams().page()),
      ),
    );
    await tester.pumpAndSettle();

    // 药丸：夹具 ep='全12集' 不是纯数字，按官方 ≤1 分支显示「观看全片」。
    expect(find.text('观看全片'), findsOneWidget);
    // 即使回包仍有追剧人数，短剧也不再显示追剧入口或计数。
    expect(find.text('4.6万'), findsNothing);
    // 分类 chip（`d6f.xml` 的 `hdm` 行，12sp 白字 #33FFFFFF 底）。
    expect(find.text('喜剧'), findsOneWidget);
    // 简言行默认 2 行截断，带「展开」；点开后全文显示、「展开」消失。
    expect(find.textContaining('第1集丨一个长生却会老的穿越者'), findsOneWidget);
    expect(find.text('展开'), findsOneWidget);
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(find.text('展开'), findsNothing);
    expect(find.textContaining('展开按钮'), findsOneWidget);
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
    // 用户已移除右侧追剧入口。
    expect(find.text('追剧'), findsNothing);
    // The shell mounts its own DramaPage without seams, so its inline session
    // starts a real directory request here. Advance past the client timeout to
    // drain that timer, which would otherwise outlive the test.
    await tester.pump(const Duration(seconds: 25));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '最近 tab：官方筛选 chips、漫剧角标与已看到第N集',
    timeout: Timeout(const Duration(minutes: 1)),
    (tester) async {
      // 官方截图第二十三轮：chips 行（全部/短剧/漫剧，选中橙字浅橙底）、
      // 封面左上「漫剧」角标 + 居中半透明 ▶、两行标题、灰字「已看到第N集」。
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      // Hive 是真实文件 IO，必须逃出 FakeAsync 时区（runAsync），否则
      // await 永不完成——这正是这用例第一次跑挂满 10 分钟的原因。
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final now = DateTime.now().millisecondsSinceEpoch;
        final history = await Hive.openBox<dynamic>('history');
        await history.put('d-video', {
          'id': 'd-video',
          'kind': 'video',
          'title': '全球杀机 作品',
          'episode': 0,
          'ep': '82',
          'time': now,
        });
        await history.put('d-manju', {
          'id': 'd-manju',
          'kind': 'manju',
          'title': '仙渊道尘 作品',
          'episode': 0,
          'time': now - 1000,
        });
        await LibraryStore.instance.init();
        await SwipeGuideStore.instance.markShown();
      });

      await tester.pumpWidget(
        _scope(perTab: 1, child: MaterialApp(home: _Seams().page())),
      );
      await _flush(tester);
      await tester.tap(find.text('最近'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drama_最近_grid')), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('已看到第1集'), findsNWidgets(2));
      // 「漫剧」出现在 chip、封面角标与频道条上，共 3 处。
      expect(find.text('漫剧'), findsNWidgets(3));
      expect(find.text('全球杀机 作品'), findsOneWidget);

      // 漫剧 chip（作用域限定在筛选行，避免命中频道条）→ 只剩漫剧卡。
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('drama_recent_filter')),
          matching: find.text('漫剧'),
        ),
      );
      await _flush(tester);
      expect(find.text('仙渊道尘 作品'), findsOneWidget);
      expect(find.text('全球杀机 作品'), findsNothing);
      expect(find.text('已看到第1集'), findsOneWidget);

      // 短剧 chip → 只剩短剧卡；全部 → 两张都回来。
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('drama_recent_filter')),
          matching: find.text('短剧'),
        ),
      );
      await _flush(tester);
      expect(find.text('全球杀机 作品'), findsOneWidget);
      expect(find.text('仙渊道尘 作品'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('drama_recent_filter')),
          matching: find.text('全部'),
        ),
      );
      await _flush(tester);
      expect(find.text('全球杀机 作品'), findsOneWidget);
      expect(find.text('仙渊道尘 作品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '收藏 tab：官方筛选行与编辑/删除（VideoCollectionDeliveryFragmentImpl 形态）',
    timeout: Timeout(const Duration(minutes: 1)),
    (tester) async {
      // 反编译：收藏同样有编辑头/长按进编辑/删除专用底条（`bb3.p0`）与
      // GenreScrollTabLayout 筛选行；编辑头标题 `ye()` 在筛选「全部」时就是
      // 「全部」；删除确认框是「确认删除吗？」+ 按钮文案「删除」。
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        await LibraryStore.instance.init();
        await ShelfStore.instance.init();
        await ShelfStore.instance.clear();
        await ShelfStore.instance.add(
          MediaItem(
            id: 's-video',
            title: '收藏短剧甲',
            cover: '',
            author: '',
            badge: '',
            ep: '24',
            kind: 'video',
          ),
        );
        await ShelfStore.instance.add(
          MediaItem(
            id: 's-manju',
            title: '收藏漫剧乙',
            cover: '',
            author: '',
            badge: '',
            ep: '',
            kind: 'manju',
          ),
        );
        await SwipeGuideStore.instance.markShown();
      });

      await tester.pumpWidget(
        _scope(perTab: 1, child: MaterialApp(home: _Seams().page())),
      );
      await _flush(tester);
      // 频道条是横向 ListView，360dp 宽度下「收藏」与右端搜索按钮重叠，
      // 先把条带往左滚再点（真机上手指也会这么做）。
      await tester.drag(find.text('推荐'), const Offset(-120, 0));
      await _flush(tester);
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drama_收藏_grid')), findsOneWidget);

      // 长按进编辑并选中该卡（官方 type=long_press）：出现收藏专用删除底条。
      await tester.longPress(find.text('收藏短剧甲'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drama_shelf_bottom_bar')), findsOneWidget);
      expect(find.byKey(const Key('drama_shelf_delete')), findsOneWidget);
      // 已选择后缀 = 官方 `xe()`：漫剧/短剧之外一律「视频」。
      expect(find.text('已选择 1 个视频'), findsOneWidget);

      // 全选 → 删除 → 官方确认框「确认删除吗？」。
      await tester.tap(find.byKey(const Key('drama_recent_select_all')));
      await _flush(tester);
      expect(find.text('已选择 2 个视频'), findsOneWidget);
      await tester.tap(find.byKey(const Key('drama_shelf_delete')));
      await tester.pumpAndSettle();
      expect(find.text('确认删除吗？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('drama_shelf_delete_confirm')));
      await tester.pumpAndSettle();
      // Hive 的写 Future 在真实异步里完成（删除即时生效于内存，revision
      // 通知却等持久化 resolve），测试的 fake-async 需要放行真实时钟。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      // 官方删除成功后 500ms 才退编辑（postInForeground 500ms），先推时间
      // 触发这个 Timer，避免测试收尾时报 Timer 挂起。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('暂无收藏内容'), findsOneWidget);
      expect(ShelfStore.instance.records(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('服务端频道表替换本地频道条（F08）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: _Seams().page(
            channelLoader: () async => const ChannelTable(
              tabs: [
                // 短剧语境条带的特征：16 这条 feed 叫「推荐」。
                ChannelTab(type: kChannelVideoFeed, title: '推荐'),
                ChannelTab(type: kChannelVideoEpisode, title: '看剧'),
                ChannelTab(type: kChannelRecent, title: '看过'),
              ],
            ),
          ),
        ),
      ),
    );
    await _flush(tester);
    // 名字来自服务端 title，顺序也按服务端给的顺序。
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('看剧'), findsOneWidget);
    expect(find.text('看过'), findsOneWidget);
    // 本地表里没被服务端下发的频道不该再出现。
    expect(find.text('收藏'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务端频道表取不到时保留本地表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: _Seams().page(
            channelLoader: () async => const ChannelTable(tabs: <ChannelTab>[]),
          ),
        ),
      ),
    );
    await _flush(tester);
    // 本地兜底里「收藏」在，服务端专用名不在。
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('精选'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('频道表加载失败时保留本地表且不抛异常', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: _Seams().page(
            channelLoader: () async => throw const ApiException('频道表不可用'),
          ),
        ),
      ),
    );
    await _flush(tester);
    expect(find.text('收藏'), findsOneWidget, reason: '失败要退回本地频道表');
    expect(tester.takeException(), isNull);
  });

  testWidgets('只映射出一个频道时不替换整条栏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: _Seams().page(
            channelLoader: () async => const ChannelTable(
              tabs: [ChannelTab(type: kChannelVideoFeed, title: '精选')],
            ),
          ),
        ),
      ),
    );
    await _flush(tester);
    // 一条频道顶掉整栏会把用户锁死在单一频道，所以仍然用本地表。
    expect(find.text('精选'), findsNothing);
    expect(find.text('收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('书城语境的频道条不替换（16 被叫「视频」）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: _Seams().page(
            channelLoader: () async => const ChannelTable(
              // 本上游 bookmall/tab/v 实际回的书城条（2026-09-27 loopback
              // 取证）：只有 8/16 可映射，且 16 叫「视频」。
              tabs: [
                ChannelTab(type: kChannelVideoEpisode, title: '看剧'),
                ChannelTab(type: kChannelVideoFeed, title: '视频'),
              ],
            ),
          ),
        ),
      ),
    );
    await _flush(tester);
    // 整栏换上去会把频道条塌成 看剧/视频 并收走最近/收藏 —— 必须保留本地表。
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('漫剧'), findsOneWidget);
    expect(find.text('最近'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('视频'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('映射不到的类型被丢掉，可映射的仍生效', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: _Seams().page(
            channelLoader: () async => const ChannelTable(
              tabs: [
                // 官方枚举里的类型，但本地没有对应内容源。
                ChannelTab(type: kChannelVideo, title: '看剧'),
                ChannelTab(type: kChannelVideoFeed, title: '推荐'),
                ChannelTab(type: kChannelVideoEpisode, title: '正片'),
              ],
            ),
          ),
        ),
      ),
    );
    await _flush(tester);
    // `video` 能映射到「看剧」，所以三者都留；但 `收藏` 不该出现。
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('收藏'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('漫剧频道是三列海报格，不是竖滑播放流（官方 StaggeredFeedTab 形态）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: _Seams().page(
            channelLoader: () async => const ChannelTable(
              tabs: [
                ChannelTab(type: kChannelVideoFeed, title: '推荐'),
                ChannelTab(type: kChannelVideoEpisode, title: '看剧'),
                ChannelTab(type: kChannelDynamicComic, title: '漫剧'),
              ],
            ),
          ),
        ),
      ),
    );
    await _flush(tester);
    await tester.tap(find.text('漫剧'));
    await _flush(tester);
    // 漫剧 = 网格（数据来自 tab_type 24 的流），不再挂竖滑 feed。
    expect(find.byKey(const Key('drama_manju_grid')), findsOneWidget);
    expect(find.byKey(const Key('drama_feed')), findsNothing);
    expect(find.text('24-0 作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('看剧频道是两列海报格，点击直接进播放页（官方 CommonDoubleRow 形态）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: _Seams().page(
            channelLoader: () async => const ChannelTable(
              tabs: [
                ChannelTab(type: kChannelVideoFeed, title: '推荐'),
                ChannelTab(type: kChannelVideoEpisode, title: '看剧'),
              ],
            ),
          ),
        ),
      ),
    );
    await _flush(tester);
    await tester.tap(find.text('看剧'));
    await _flush(tester);
    expect(find.byKey(const Key('drama_episode_grid')), findsOneWidget);
    expect(find.byKey(const Key('drama_feed')), findsNothing);
    expect(find.text('8-0 作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('频道表替换后按 tab_type 续接当前频道（条与 feed 不能对不上）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: _Seams().page(
            channelLoader: () async => const ChannelTable(
              tabs: [
                // 本地选中的是「推荐」（tab_type 16），服务端把同一条流排在了
                // 第二位：续接要看类型而不是位置。
                ChannelTab(type: kChannelVideoEpisode, title: '看剧'),
                ChannelTab(type: kChannelVideoFeed, title: '推荐'),
              ],
            ),
          ),
        ),
      ),
    );
    await _flush(tester);
    expect(find.text('推荐'), findsOneWidget);
    // 高亮的是「推荐」（tab_type 16），所以下面的 feed 必须还是 16 的内容，
    // 不能因为换表就跳到第一条「看剧」（tab_type 8）。
    expect(find.text('16-0 作品'), findsOneWidget);
    expect(find.text('8-0 作品'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首帧只加载选中频道的流，不再先打 provider 初始的短剧 tab', (
    tester,
  ) async {
    // 2026-09-28 真机跳变复盘：initState 无条件 load() 打的是 provider
    // 出厂的 tabIndex=2（短剧，tab_type 8），而可见频道是推荐
    // （tabIndex=6，tab_type 16）——1~2s 后频道表回来 selectTab(6) 把
    // 可见列表整换成另一份快照并起播。官方不变量是"只挂载选中频道的
    // 流"（SeriesMallFragment.Fh/Gh 只 attach selectIndex 那个 fragment）。
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    final tabTypes = <int>[];
    // 频道表永不返回：把 F08 替换路径隔离掉，只观察首帧加载。
    final hangingChannels = Completer<ChannelTable>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(() => _notifier()),
          dramaProvider.overrideWith(
            () => HomeNotifier(
              initialTabIndex: dramaTabIndex,
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    tabTypes.add(tabType);
                    return HomepagePage(
                      items: [_item('$tabType-0')],
                      nextOffset: null,
                      sessionId: null,
                    );
                  },
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: MaterialApp(
          home: _Seams().page(channelLoader: () => hangingChannels.future),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 只有一次请求，且是推荐频道自己的 tab_type 16。
    expect(tabTypes, [16]);
    expect(find.text('16-0 作品'), findsOneWidget);
    expect(find.text('8-0 作品'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('feed 卡片标题行「剧名 >」进剧集详情页，点选集经目录推播放页', (
    tester,
  ) async {
    // 官方 ql3/v0.a1()：feed 信息区标题点击 enter_from="title"，落点
    // series_detail（此前误接成播放/暂停，用户真机反馈点不动）。
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    const nativeChannel = MethodChannel('fqapp/native_player');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      nativeChannel,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        null,
      ),
    );
    final seams = _Seams(failContent: false);
    await tester.pumpWidget(
      _scope(
        child: MaterialApp(
          home: seams.page(
            directoryLoader: (id, tab) async => [
              [
                Chapter(itemId: '$id-1', title: '第1集', volumeName: '剧集'),
                Chapter(itemId: '$id-2', title: '第2集', volumeName: '剧集'),
              ],
            ],
            seriesDetailLoader: (_) async => const SeriesDetail(
              seriesId: '2-0',
              title: '2-0 作品',
              cover: '',
              episodeCount: 2,
              status: 1,
            ),
            seriesCommentLoader: (_) async => const PlayletCommentPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点标题行 → 详情页（feed 侧 entry，无播放器实例跟随）。
    await tester.tap(find.byKey(const Key('drama-series-title')));
    await _flush(tester);
    await tester.pumpAndSettle();
    expect(find.byType(SeriesDetailPage), findsOneWidget);
    expect(find.byKey(const ValueKey('series-detail-page')), findsOneWidget);
    expect(find.text('2-0 作品'), findsWidgets);

    // 详情页点选集格 → pop 详情回 feed，再经 _openPlayer 拉目录推播放页
    // （下层路由保持挂载是 MaterialApp 的常态，只断言播放器在顶上）。
    await tester.tap(find.byKey(const ValueKey('series-episode-1')));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    expect(find.byType(PlayerPage), findsOneWidget);
  });
}
