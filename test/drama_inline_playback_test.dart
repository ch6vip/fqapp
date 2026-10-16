import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/digg_store.dart';
import 'package:fqapp/services/drama_mute_preferences.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/swipe_guide_store.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_layer.dart';

import 'support/controlled_player.dart';

MediaItem _item(String label, {bool aiGenerated = false, String intro = ''}) =>
    MediaItem(
      id: label,
      title: '$label 作品',
      cover: '',
      author: '演员',
      badge: '',
      ep: '全12集',
      kind: 'video',
      intro: intro,
      aiGenerated: aiGenerated,
    );

/// One mounted feed with its own fake players, address loader and history
/// store. Nothing in this session touches the network or Hive writes.
class _Session {
  _Session({this.hasFirstFrame = true, this.width = 1920, this.height = 1080});

  final bool hasFirstFrame;

  /// What the fake decoder reports; the inline letterbox must follow it.
  final int width;
  final int height;
  List<Size> playerSizes = const [];
  final players = <ControlledNativePlayer>[];
  final directoryCalls = <String>[];
  final contentCalls = <String>[];
  final store = ControlledReaderStore();
  Object? failure;

  /// Items per tab the fake backend answers with. Mutable on purpose: a test
  /// flips it to 0 and re-loads to drive the feed empty mid-playback.
  int itemsPerTab = 4;

  /// 热评加载缝的返回值，键为剧 id。未预置的剧回空（行不显示）。
  final Map<String, List<PlayletComment>> hotComments = {};

  /// 置真后所有条目带 `ai_usage_type > 0`（作者声明行）。
  bool aiGeneratedItems = false;

  /// 条目简介文案（官方信息槽的「第1集丨…」回落行）。
  String itemIntro = '';

  /// 内容回包附带的多档流名（官方清晰度行的数据源；空 = 单流，行隐藏）。
  List<String> variantNames = [];

  /// The two notifiers the page's providers resolve to; kept as fields so a
  /// test can re-load the feed without a gesture.
  late final HomeNotifier home = _notifierFor(this);
  late final HomeNotifier drama = _notifierFor(this);

  static HomeNotifier _notifierFor(_Session session) => HomeNotifier(
    initialTabIndex: dramaTabIndex,
    homepageLoader:
        ({int tabType = 2, int offset = 0, String? sessionId}) async {
          return HomepagePage(
            items: [
              for (var index = 0; index < session.itemsPerTab; index++)
                _item(
                  '$tabType-$index',
                  aiGenerated: session.aiGeneratedItems,
                  intro: session.itemIntro,
                ),
            ],
            nextOffset: null,
            sessionId: null,
          );
        },
    searchLoader: (query, {int page = 1}) async => const [],
  );

  Widget app({bool tickerEnabled = true}) => ProviderScope(
    overrides: [
      homeProvider.overrideWith(() => home),
      dramaProvider.overrideWith(() => drama),
    ],
    child: MaterialApp(
      home: TickerMode(
        enabled: tickerEnabled,
        child: DramaPage(
          directoryLoader: (id, tab) async {
            directoryCalls.add('$id:$tab');
            return [
              [Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集')],
            ];
          },
          contentLoader: (itemId, tab) async {
            contentCalls.add('$itemId:$tab');
            if (failure != null) throw failure!;
            final response = <String, dynamic>{
              'video_url': 'https://example.invalid/$itemId.mp4',
            };
            if (variantNames.isNotEmpty) {
              response['variants'] = [
                for (final (index, name) in variantNames.indexed)
                  {
                    'name': name,
                    'url': 'https://example.invalid/$itemId-$name.mp4',
                    'key_hex': '',
                    'height': 1080 - index * 180,
                  },
              ];
            }
            return response;
          },
          historyStore: store,
          hotCommentsLoader: (seriesId) async =>
              hotComments.putIfAbsent(seriesId, () => const []),
          playerFactory: () {
            final size = players.length < playerSizes.length
                ? playerSizes[players.length]
                : Size(width.toDouble(), height.toDouble());
            final player = ControlledNativePlayer(hasFirstFrame: hasFirstFrame)
              ..width = size.width.toInt()
              ..height = size.height.toInt();
            players.add(player);
            return player;
          },
        ),
      ),
    ),
  );
}

/// Bounded flushing: `pumpAndSettle` would wait for loading animations that
/// never end, and cancel stream events land on the real event loop.
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  // Unmount before the test ends, then put the shared binding back: these
  // resets have to run while the test is still in progress.
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

/// One drag moves the vertical pager exactly one page. The settle animation has
/// to finish before the new card may start.
Future<void> _swipeUp(WidgetTester tester) async {
  await tester.drag(find.byKey(const Key('drama_feed')), const Offset(0, -600));
  await tester.pumpAndSettle();
  await _flush(tester);
}

late Directory _hiveDir;

void main() {
  // The drama page reads the local shelf (for 追剧) from the store, so the box
  // has to exist before the first build.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
    _hiveDir = await Directory.systemTemp.createTemp('fqapp-drama-inline-');
    Hive.init(_hiveDir.path);
    await ShelfStore.instance.init();
    // The card's 点赞 button writes the same kind of local box.
    await DiggStore.instance.init();
    // 引导提示的 8s 定时器会挂住用例收尾，默认按已显示过处理。
    // 播放页的横滑引导同理（ SwipeGuideStore 已打开，不预置就会弹出）。
    await SwipeGuideStore.instance.init();
    await SwipeGuideStore.instance.markShown();
    await SwipeGuideStore.instance.markSeekHintShown();
  });

  // The binding resets (surface size, lifecycle) live in _mount's tear-down:
  // `setSurfaceSize` asserts that the test is still running.
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
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

  testWidgets('首卡自动起播，首帧到达前保留封面', (tester) async {
    final session = _Session(hasFirstFrame: false);
    await _mount(tester, session);

    expect(session.directoryCalls, ['16-0:短剧']);
    expect(session.players, hasLength(1));
    final player = session.players.single;
    expect(player.calls.where((call) => call.startsWith('create:')), [
      'create:https://example.invalid/16-0-1.mp4',
    ]);
    expect(player.calls.where((call) => call == 'play'), ['play']);
    expect(player.playbackRequested, isTrue);

    // Exactly one texture, owned by the on-screen card.
    expect(find.byType(Texture), findsOneWidget);
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-0')),
      findsOneWidget,
    );
    // `create` completing is not a frame: the cover stays in front.
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_16-0')),
      findsOneWidget,
    );

    player.emitFirstFrame();
    await _flush(tester);
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_16-0')),
      findsNothing,
    );
    expect(find.byType(Texture), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // P1-15：feed 内联播放的 inactive（通知栏/控制中心）继续播，hidden
  // 暂停，resumed 恢复。参考 audio_page_test 的 lifecycle 循环写法。
  testWidgets('inactive keeps the feed playing, hidden pauses it', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    final player = session.players.single;
    expect(player.isPlaying, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _flush(tester);
    expect(player.isPlaying, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await _flush(tester);
    expect(player.isPlaying, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flush(tester);
    expect(player.isPlaying, isTrue);
  });

  testWidgets('内联矩形按解码尺寸排布，横屏剧不按 9:16', (tester) async {
    final session = _Session(width: 1920, height: 1080);
    await _mount(tester, session);
    final feed = tester.getRect(find.byKey(const Key('drama_feed')));
    final rect = tester.getRect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-0')),
    );
    // The letterbox follows the decoder's own ratio (16:9 here) instead of the
    // 9:16 fallback, and the video never leaves the visible feed.
    expect(rect.width / rect.height, closeTo(16 / 9, 0.02));
    expect(rect.left, greaterThanOrEqualTo(feed.left - 0.5));
    expect(rect.right, lessThanOrEqualTo(feed.right + 0.5));
    expect(rect.top, greaterThanOrEqualTo(feed.top - 0.5));
    expect(rect.bottom, lessThanOrEqualTo(feed.bottom + 0.5));
    // 横版源：官方 `vk3.a.a` 只在非竖屏源上显示 30dp 圆形全屏钮。
    expect(find.byKey(const Key('drama_fullscreen_button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('竖屏短剧铺满卡片（官方 mode 4 = cover），只裁边缘', (tester) async {
    final session = _Session(width: 1080, height: 1920);
    await _mount(tester, session);

    final feed = tester.getRect(find.byKey(const Key('drama_feed')));
    final rect = tester.getRect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-0')),
    );
    // 官方 `cq3/o.java:181` 起手就是 mode 4（fill），9:16 源的宽高比 0.5625
    // 低于 `landscapeRatio` 1.666，所以不降级、按 cover 铺满整个卡片：
    // 比例仍是 9:16，两条轴都够到卡片，溢出的部分由 Stack 裁掉。
    expect(rect.width / rect.height, closeTo(9 / 16, 0.02));
    expect(rect.left, lessThanOrEqualTo(feed.left + 0.5));
    expect(rect.right, greaterThanOrEqualTo(feed.right - 0.5));
    expect(rect.top, lessThanOrEqualTo(feed.top + 0.5));
    expect(rect.bottom, greaterThanOrEqualTo(feed.bottom - 0.5));
    // 居中铺满，所以裁切是对称的。
    expect(rect.center.dx, closeTo(feed.center.dx, 0.5));
    expect(rect.center.dy, closeTo(feed.center.dy, 0.5));
    // 竖屏源：官方 `vk3.a.a` 不显示圆形全屏钮（入口只有药丸）。
    expect(find.byKey(const Key('drama_fullscreen_button')), findsNothing);
    // `getRect` 返回的是未裁剪的布局矩形，所以溢出不会被上面几条发现：
    // 真正把画面裁到卡片里的是祖先 `ClipRRect`（`drama_page.dart:916`）。
    // 没有它，铺满就会画到卡片外面。
    final clipper = tester.widget<ClipRRect>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('drama_inline_texture_video_16-0')),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(clipper.clipBehavior, isNot(Clip.none));
    expect(
      clipper.borderRadius,
      BorderRadius.circular(12),
      reason: '官方 cjc.xml 的视频面圆角 @dimen/a1t = 12dp',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('上滑把旧播放器放进池而不是销毁，只留一个纹理', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    final first = session.players.single;
    expect(first.isPlaying, isTrue);

    await _swipeUp(tester);

    // 官方语义（`gq3.b` ShortPlayerSharePool）：滑走的播放器被**暂停后放进池**，
    // 不是销毁，所以滑回来能接着播。
    expect(first.disposed, isFalse);
    expect(first.calls, contains('pause'));
    expect(first.isPlaying, isFalse);
    expect(
      first.calls.where((call) => call.startsWith('create:')),
      hasLength(1),
    );
    expect(session.players, hasLength(2));
    final second = session.players.last;
    expect(second.calls, contains('create:https://example.invalid/16-1-1.mp4'));
    expect(second.isPlaying, isTrue);

    // 只有屏幕上那张卡挂纹理。
    expect(find.byType(Texture), findsOneWidget);
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-0')),
      findsNothing,
    );
    expect(find.text('16-1 作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容刷新成空列表时，播放中的播放器入池前先暂停', (tester) async {
    // 2026-09-27 真机回归：feed 起播后一次无滚动的刷新把内容换成空列表，
    // `_syncInline` 走 `release()` 入池——此前入池不暂停，没挂 surface 的
    // 僵尸继续出声（默认有声后用户听得见）。官方入池前先 pause
    // （`jq3/x.java:4681`），池现在自己兜底，这里钉住整条链路。
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    final first = session.players.single;
    expect(first.isPlaying, isTrue);

    session.itemsPerTab = 0;
    await session.drama.load();
    await _flush(tester);

    expect(find.text('暂无符合条件的短剧'), findsOneWidget);
    // release 是入池不是销毁：滑回来还要复用同一个解码器。
    expect(first.disposed, isFalse);
    expect(first.calls, contains('pause'));
    expect(first.isPlaying, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('滑回上一部剧复用池里的播放器，不再新建', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    final first = session.players.single;

    await _swipeUp(tester);
    expect(session.players, hasLength(2));
    expect(first.disposed, isFalse);

    // 滑回去：第 1 部剧的播放器还在池里，应当被取回复用。
    await tester.drag(
      find.byKey(const Key('drama_feed')),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    await _flush(tester);

    expect(session.players, hasLength(2), reason: '复用了池里的播放器，没有新建');
    expect(first.disposed, isFalse);
    expect(first.isPlaying, isTrue);
    expect(
      first.calls.where((call) => call.startsWith('create:')),
      hasLength(1),
      reason: '同一个解码器被复用，不能再次 create',
    );
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-0')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('上滑后第二张卡挂的是视频层，不是只有封面', (tester) async {
    // 回归：`onPageChanged` 曾经只改 `_screenIndex` 而没 `setState`，于是卡片
    // 列表不重建：会话已经切到第 2 部剧、播放器也在解码，但 `video` 仍留在
    // 第 1 张卡上，第 2 张永远显示封面。
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-0')),
      findsOneWidget,
    );

    await _swipeUp(tester);

    // 第 2 张卡拿到纹理，且它的封面已经被首帧替换掉。
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_16-1')),
      findsNothing,
    );
    expect(find.byType(Texture), findsOneWidget);

    // 第 1 张卡不再持有任何视频层。
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_16-0')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('滑走后进全屏观看会清空池，不留第二个播放器', (tester) async {
    // 官方约束：两个 ExoPlayer 不能同时活着。滑走会把播放器放进池，所以推
    // 全页播放器之前必须连池一起清掉（`disposePlayer`）。
    final session = _Session();
    await _mount(tester, session);
    final first = session.players.single;

    await _swipeUp(tester);
    expect(session.players, hasLength(2));
    expect(first.disposed, isFalse, reason: '刚滑走时被放进池');

    // 官方进全页播放器的入口是「观看全集」药丸（`nk3.c.e`）；圆形全屏钮只在
    // 横版解码尺寸下出现，夹具没有解码尺寸，所以这里用药丸。
    await tester.tap(find.byKey(const Key('drama_episode_pill')));
    // Not `pumpAndSettle`: the push keeps a spinner running. The pool teardown
    // happens before the page is pushed, so a couple of flushes is enough.
    await _flush(tester);
    await _flush(tester);

    // `first` was parked by the swipe; the pool must be emptied on the way to
    // the full page player, and the inline session's own player freed with it.
    expect(first.disposed, isTrue, reason: '进播放页时池必须被清空');
    expect(session.players, hasLength(greaterThanOrEqualTo(3)));
    expect(
      session.players[1].disposed,
      isTrue,
      reason: '内联会话的播放器也要销毁，不能和播放页那个并存',
    );
    // The only live player is the one the full page player created.
    final live = session.players.where((p) => !p.disposed).toList();
    expect(live, hasLength(1));
    expect(live.single, same(session.players.last));
    expect(tester.takeException(), isNull);
  });

  testWidgets('小幅拖动回弹后继续播放同一张卡', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    final player = session.players.single;

    // Not enough to change the page: this stops and restarts the same card.
    await tester.drag(
      find.byKey(const Key('drama_feed')),
      const Offset(0, -60),
    );
    await tester.pumpAndSettle();
    await _flush(tester);

    expect(player.calls, contains('pause'));
    expect(player.disposed, isFalse);
    expect(player.isPlaying, isTrue);
    expect(session.players, hasLength(1));
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-0')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('离开页面即停播并释放播放器', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    final player = session.players.single;
    expect(player.isPlaying, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);

    expect(player.calls, contains('pause'));
    expect(player.disposed, isTrue);
    expect(find.byType(Texture), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏的底部 tab 只暂停，不重建播放器', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    final player = session.players.single;

    await tester.pumpWidget(session.app(tickerEnabled: false));
    await _flush(tester);

    expect(player.calls, contains('pause'));
    expect(player.isPlaying, isFalse);
    expect(player.disposed, isFalse);
    expect(session.players, hasLength(1));

    await tester.pumpWidget(session.app());
    await _flush(tester);
    expect(player.isPlaying, isTrue);
    expect(session.players, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('看剧海报格不在背后起播，切回推荐才重新播放', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    final feedPlayer = session.players.single;
    expect(feedPlayer.isPlaying, isTrue);

    final historyWrite = Completer<void>();
    session.store.writeGate = historyWrite;
    await tester.tap(find.text('看剧'));
    await _flush(tester);
    await _flush(tester);

    expect(find.byKey(const Key('drama_episode_grid')), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
    expect(feedPlayer.isPlaying, isFalse);
    expect(feedPlayer.disposed, isTrue);
    expect(session.players, hasLength(1), reason: '海报格不应创建隐藏播放器');

    historyWrite.complete();
    await _flush(tester);
    await tester.tap(find.text('推荐'));
    await _flush(tester);
    expect(session.players, hasLength(2));
    expect(session.players.last.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容加载失败回到封面并给出重试', (tester) async {
    final session = _Session()..failure = const ApiException('内容加载失败');
    await _mount(tester, session);

    expect(session.players, isEmpty);
    expect(find.byType(Texture), findsNothing);
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_16-0')),
      findsOneWidget,
    );
    expect(find.text('内容加载失败'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('drama_inline_retry_video_16-0')),
      findsOneWidget,
    );

    expect(tester.takeException(), isNull);

    final callsBefore = session.contentCalls.length;
    await tester.tap(
      find.byKey(const ValueKey('drama_inline_retry_video_16-0')),
    );
    await _flush(tester);
    expect(session.contentCalls.length, greaterThan(callsBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('带外长按 2 倍速，松手回到按之前的速率，进度条可拖动', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    // 进度条只在拿到时长后才出现（`cjt.xml` 的 16dp 条随 duration 走）。
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);
    // 官方 `needMutePlay` 初始 false：出厂有声起播、无「取消静音」药丸
    //（`tm3/b.java`、`holder/a.java:640 setIsMute(needMutePlay)`）。
    expect(session.players.single.calls, contains('volume:1.0'));
    expect(find.byKey(const Key('drama_mute_hint')), findsNothing);

    // 带外长按 = 官方速度层（`@string/ec6`=「2倍速快进中」，`cjx.xml`）。
    // 中带留给更多面板，所以这里按在左 10% 处。松开回到按之前的速率。
    final plane = tester.getRect(find.byKey(const Key('drama_card_gestures')));
    final gesture = await tester.startGesture(
      Offset(plane.left + plane.width * 0.1, plane.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await _flush(tester);
    expect(session.players.single.calls, contains('rate:2.0'));
    expect(find.byKey(const Key('drama_rate_hint')), findsOneWidget);
    expect(find.text('2倍速快进中'), findsOneWidget);

    await gesture.up();
    await _flush(tester);
    expect(session.players.single.calls, contains('rate:1.0'));
    expect(find.byKey(const Key('drama_rate_hint')), findsNothing);

    // 进度条（`cjt.xml`）：拿到时长后才显示，横向拖动 = seek。
    expect(find.byKey(const Key('drama_seek_bar')), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('drama_seek_bar')),
      const Offset(120, 0),
    );
    await _flush(tester);
    expect(
      session.players.single.calls.any((call) => call.startsWith('seek:')),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('中带长按打开更多面板，选倍速生效并持久化，不挂快进提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);

    // 中带（官方 jq3/x.K6：竖屏 50% 居中）长按 = y7() → 更多面板。
    // tester.longPress 默认按控件中心，正好在带内。发布配置不下发
    // play_control_panel_style_v681.style → 浅色分支（用户设备同款）。
    await tester.longPress(find.byKey(const Key('drama_card_gestures')));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    expect(
      find.byKey(const ValueKey('player-more-light-panel')),
      findsOneWidget,
    );
    expect(find.text('倍速'), findsOneWidget);
    // feed 面板与官方同一条 oi3/k 行集（2026-10-11 补齐）：清晰度要会话
    // 真有多档流（本夹具单流 → 行隐藏，官方 oi3/k.P() 门），其余行都是
    // 真功能入口。
    expect(find.text('清晰度'), findsNothing);
    expect(find.text('清屏播放'), findsOneWidget);
    expect(find.text('弹幕'), findsOneWidget);
    expect(find.text('离线缓存'), findsOneWidget);
    expect(find.text('听视频'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
    // 浅色支没有取消行（官方 aae 布局同款）。
    expect(find.text('取消'), findsNothing);

    // 选 1.25x：药丸点击立即回传（官方 jj3/i.e 语义），feed 播放器生效并
    // 写入全局速率配置（全页播放页读同一份）。面板退场动画跨帧推进。
    await tester.tap(find.byKey(const ValueKey('player-more-light-rate-1.25')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await _flush(tester);
    expect(find.byKey(const ValueKey('player-more-light-panel')), findsNothing);
    expect(session.players.single.calls, contains('rate:1.25'));
    expect(await PlayerPreferences.loadPlaybackRate(), 1.25);
    // 面板选速不是快进：速率≠1 也不出现「2倍速快进中」。
    expect(find.byKey(const Key('drama_rate_hint')), findsNothing);

    // 之后带外长按，松手必须回到面板选过的 1.25，而不是硬编码的 1.0。
    final plane = tester.getRect(find.byKey(const Key('drama_card_gestures')));
    final gesture = await tester.startGesture(
      Offset(plane.left + plane.width * 0.1, plane.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await _flush(tester);
    expect(session.players.single.calls, contains('rate:2.0'));
    expect(find.byKey(const Key('drama_rate_hint')), findsOneWidget);
    await gesture.up();
    await _flush(tester);
    expect(session.players.single.calls, contains('rate:1.25'));
    expect(find.byKey(const Key('drama_rate_hint')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('冷启动倍速读全局配置，起播即按持久化档位播放', (tester) async {
    // 更多面板选过 1.25x 后冷启动：官方全局配置对 feed 新播放器同样生效。
    SharedPreferences.setMockInitialValues({'player_playback_rate': 1.25});
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);
    expect(session.players.single.calls, contains('rate:1.25'));
    expect(find.byKey(const Key('drama_rate_hint')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('在屏卡热评整行替换简介槽，点击打开评论面板', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _Session(hasFirstFrame: true)
      ..itemIntro = '被公司开除的范理拒绝内耗，转身开起早餐店';
    session.hotComments['16-0'] = const [
      PlayletComment(id: 'hot-1', text: '这剧可以看，有种《万万没想到》的味道'),
    ];
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);
    // 官方 cj3.xml：InfoPanelHotCommentView(drs) 与简介 ExtendTextView(m6)
    // 同槽约束，热评在场时整行替换简介。
    expect(find.text('热评'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('playlet-hot-comment-hot-1')),
      findsOneWidget,
    );
    expect(find.textContaining('第1集丨'), findsNothing);

    // 点击 = 官方 SeriesHotCommentView.E：打开评论面板并定点到该条。
    await tester.tap(find.byKey(const ValueKey('playlet-hot-comment-hot-1')));
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    expect(find.byKey(const ValueKey('playlet-comment-title')), findsOneWidget);
    // 收起面板后热评行仍在。
    await tester.tap(find.byKey(const ValueKey('playlet-comment-close')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    expect(find.text('热评'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('热评不在场回落简介行，ai_usage_type > 0 显示作者声明行', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _Session(hasFirstFrame: true)
      ..aiGeneratedItems = true
      ..itemIntro = '被公司开除的范理拒绝内耗，转身开起早餐店';
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);
    // 无热评：简介行照旧；声明行来自 video_detail.ai_usage_type。
    expect(find.textContaining('第1集丨'), findsOneWidget);
    expect(find.text('热评'), findsNothing);
    expect(find.text('作者声明：内容由AI生成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('开启「开启应用时默认静音」后静音起播，点药丸解除', (tester) async {
    // 官方持久层 `open_mute_when_cold_start`（默认 false）：开启后短剧会话
    // 静音起播并出现「取消静音」药丸（`mq3.c`+`bvf.xml`）；点击取消静音后
    // 药丸直接消失（`z.y5` → setVisibility(GONE)），反馈走 toast。
    SharedPreferences.setMockInitialValues({
      'drama_mute_when_cold_start': true,
    });
    // store 是进程级单例，前面用例已把 `_loaded` 置位；不 reset 就读不到
    // 这份 mock 初值（整文件跑挂、单跑过的根因）。
    DramaMutePreferences.instance.resetForTest();
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    await _flush(tester);
    expect(session.players.single.calls, contains('volume:0.0'));
    expect(find.byKey(const Key('drama_mute_hint')), findsOneWidget);
    expect(find.text('取消静音'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drama_mute_hint')));
    await _flush(tester);
    expect(session.players.single.calls, contains('volume:1.0'));
    expect(find.byKey(const Key('drama_mute_hint')), findsNothing);
    expect(find.text('已开启声音'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多面板清晰度换档回跳进度，并等待新档尺寸后再显示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _Session(hasFirstFrame: true)
      ..variantNames = ['1080P', '540P']
      ..playerSizes = [const Size(1920, 1080), Size.zero];
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    session.players.single.emitPosition(const Duration(seconds: 30));
    await _flush(tester);

    await tester.longPress(find.byKey(const Key('drama_card_gestures')));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    expect(find.text('清晰度'), findsOneWidget);
    expect(find.text('1080P'), findsOneWidget);
    expect(find.text('540P'), findsOneWidget);

    // 选 1080P（官方 bgw）：Toast 立即出，不等换流完成。
    await tester.tap(find.byKey(const ValueKey('player-more-light-quality-0')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('清晰度已成功切换至1080P'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await _flush(tester);
    expect(find.byKey(const ValueKey('player-more-light-panel')), findsNothing);
    // 旧解码器销毁（换档不是入池），新解码器按所选档重建并回跳 30s。
    expect(session.players, hasLength(2));
    expect(session.players.first.calls, contains('dispose'));
    final created = session.players.last.calls
        .whereType<String>()
        .where((call) => call.startsWith('create:'))
        .toList();
    expect(created, hasLength(1));
    expect(created.single, endsWith('-1080P.mp4'));
    expect(session.players.last.calls, contains('seek:30000ms'));
    // The new decoder's first-frame event can arrive before its size event.
    // Keep the old cover in front rather than stretching the texture to the
    // fallback ratio or reusing the previous rendition's geometry.
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_16-0')),
      findsOneWidget,
    );
    session.players.last.emitVideoSize(1080, 1920);
    await _flush(tester);
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_16-0')),
      findsNothing,
    );
    final textureRect = tester.getRect(
      find.byKey(const ValueKey('drama_inline_texture_video_16-0')),
    );
    expect(textureRect.width / textureRect.height, closeTo(9 / 16, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多面板清屏播放行隐藏信息层，退出清屏行恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);
    expect(find.byKey(const Key('drama_seek_bar')), findsOneWidget);
    expect(find.text('观看全片'), findsOneWidget);

    await tester.longPress(find.byKey(const Key('drama_card_gestures')));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    await tester.tap(find.byKey(const ValueKey('player-more-light-clear')));
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    // 面板退出与清屏重排的动画有重叠窗口，多泵一程让它走完。
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    // 清屏态：进度条与信息层整批隐藏，出口只剩面板行（官方旧底栏形态）。
    expect(find.byKey(const ValueKey('player-more-light-panel')), findsNothing);
    expect(find.byKey(const Key('drama_seek_bar')), findsNothing);
    expect(find.text('观看全片'), findsNothing);

    await tester.longPress(find.byKey(const Key('drama_card_gestures')));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    expect(find.text('退出清屏'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-more-light-clear')));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    expect(find.byKey(const Key('drama_seek_bar')), findsOneWidget);
    expect(find.text('观看全片'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多面板弹幕开关落盘并提示，重开面板状态跟随', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);

    await tester.longPress(find.byKey(const Key('drama_card_gestures')));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    // 开关行不关面板（官方 SwitchButtonV2 的行内切换语义）。
    await tester.tap(
      find.byKey(const ValueKey('player-more-light-danmaku-row')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    expect(find.text('弹幕已关闭，长按视频可开启'), findsOneWidget);
    expect(await DanmakuPreference.load(), isFalse);

    // Scaffold 同时只显示一条 snackbar：入口动画（250ms）完成后才开始
    // 计 4s 在屏时长，之后走 250ms 退出——三段都泵到位再点第二次。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('player-more-light-danmaku-row')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    expect(find.text('弹幕已开启'), findsOneWidget);
    expect(await DanmakuPreference.load(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多面板听视频行进听书页，退出后按听到的集落历史并续播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 听书页生产用 NativePlayer.new：全局事件通道监听要在 mock 里应答，
    // 否则 MissingPluginException 逃进测试 zone（页面自身的错误已被吞掉）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player/events'),
          (call) async => null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('fqapp/native_player/events'),
            null,
          ),
    );
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);
    final episodeId = '${session.directoryCalls.first.split(':').first}-1';

    await tester.longPress(find.byKey(const Key('drama_card_gestures')));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    await tester.tap(find.byKey(const ValueKey('player-more-light-listen')));
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    // 听书页有自己的播放器：feed 解码器先进 destroy（不是入池）。
    expect(find.byKey(const ValueKey('listen-page')), findsOneWidget);
    expect(session.players.single.calls, contains('dispose'));

    await tester.tap(find.byKey(const ValueKey('listen-page-back')));
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    expect(find.byKey(const ValueKey('listen-page')), findsNothing);
    // 官方 sync_progress_strategy_listen_mode：听到的集落历史。
    expect(session.store.writes.last['episodeId'], episodeId);
    // 回到原卡续播：新解码器按显式起点激活。
    expect(session.players, hasLength(2));
    expect(
      session.players.last.calls.whereType<String>().any(
        (call) => call.startsWith('create:'),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多面板离线缓存行打开选集下载弹窗', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);

    await tester.longPress(find.byKey(const Key('drama_card_gestures')));
    await tester.pump(const Duration(milliseconds: 300));
    await _flush(tester);
    await tester.tap(find.byKey(const ValueKey('player-more-light-download')));
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    // 面板退出与下载弹窗进入的动画有重叠窗口，退出动画在弹窗入场后收尾。
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    expect(find.byKey(const ValueKey('player-more-light-panel')), findsNothing);
    expect(find.byKey(const ValueKey('download-sheet')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('滑回复用池内解码器后，进度写回的集号是本剧的（不再串到别的剧）', (tester) async {
    // 回归：复用路径此前不恢复 _episodes/_activeIndex，A→B→A 后一次
    // 持久化会把 B 的 episodeId 写进 A 的历史（弹幕 vid/听书起始集同源
    // 读取，一并受害）。
    SharedPreferences.setMockInitialValues({});
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    session.players.single.emitDuration(const Duration(minutes: 2));
    session.players.single.emitPosition(const Duration(seconds: 12));
    await _flush(tester);
    final firstSeriesId = session.directoryCalls.first.split(':').first;
    final firstEpisodeId = '$firstSeriesId-1';

    // A → B：A 的解码器带着「目录 + 集号」入池。
    await _swipeUp(tester);
    await _flush(tester);
    expect(session.players, hasLength(2));

    // B → A：滑回，复用池里的解码器，集号从入池记录还原。
    await tester.drag(
      find.byKey(const Key('drama_feed')),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    await _flush(tester);
    expect(session.players, hasLength(2));
    expect(session.players.first.disposed, isFalse);

    // A → 下一部剧：activate 起手持久化 A 的进度，这一次写必须指向
    // A 自己的集（串号回归点）。
    await _swipeUp(tester);
    await _flush(tester);
    final writesForFirst = session.store.writes
        .where((entry) => entry['id'] == firstSeriesId)
        .toList();
    expect(writesForFirst, isNotEmpty);
    expect(writesForFirst.last['episodeId'], firstEpisodeId);
    expect(tester.takeException(), isNull);
  });
}
