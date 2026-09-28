import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/digg_store.dart';
import 'package:fqapp/services/drama_mute_preferences.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/swipe_guide_store.dart';

import 'support/controlled_player.dart';

MediaItem _item(String label) => MediaItem(
  id: label,
  title: '$label 作品',
  cover: '',
  author: '演员',
  badge: '',
  ep: '全12集',
  kind: 'video',
);

/// One mounted feed with its own fake players, address loader and history
/// store. Nothing in this session touches the network or Hive writes.
class _Session {
  _Session({this.hasFirstFrame = true, this.width = 1920, this.height = 1080});

  final bool hasFirstFrame;

  /// What the fake decoder reports; the inline letterbox must follow it.
  final int width;
  final int height;
  final players = <ControlledNativePlayer>[];
  final directoryCalls = <String>[];
  final contentCalls = <String>[];
  final store = ControlledReaderStore();
  Object? failure;

  /// Items per tab the fake backend answers with. Mutable on purpose: a test
  /// flips it to 0 and re-loads to drive the feed empty mid-playback.
  int itemsPerTab = 4;

  /// The two notifiers the page's providers resolve to; kept as fields so a
  /// test can re-load the feed without a gesture.
  late final HomeNotifier home = _notifierFor(this);
  late final HomeNotifier drama = _notifierFor(this);

  static HomeNotifier _notifierFor(_Session session) => HomeNotifier(
    initialTabIndex: dramaTabIndex,
    homepageLoader: ({int tabType = 2, int offset = 0, String? sessionId}) async {
      return HomepagePage(
        items: [
          for (var index = 0; index < session.itemsPerTab; index++)
            _item('$tabType-$index'),
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
            return {'video_url': 'https://example.invalid/$itemId.mp4'};
          },
          historyStore: store,
          playerFactory: () {
            final player = ControlledNativePlayer(
              hasFirstFrame: hasFirstFrame,
            )
              ..width = width
              ..height = height;
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
            of: find.byKey(
              const ValueKey('drama_inline_texture_video_16-0'),
            ),
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
    await tester.drag(find.byKey(const Key('drama_feed')), const Offset(0, 600));
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
    await tester.drag(find.byKey(const Key('drama_feed')), const Offset(0, -60));
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

  testWidgets('内容加载失败回到封面并给出重试', (tester) async {
    final session = _Session()..failure = const ApiException('内容加载失败');
    await _mount(tester, session);

    expect(session.players, isEmpty);
    expect(find.byType(Texture), findsNothing);
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_16-0')),
      findsOneWidget,
    );
    expect(find.text('网络异常，请稍后再试'), findsOneWidget);
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

  testWidgets('默认有声起播，长按 2 倍速，进度条可拖动', (tester) async {
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


    // 长按 = 官方 `VideoGestureDetectLayout.onLongPress` → 2 倍速
    //（`@string/ec6`=「2倍速快进中」，`cjx.xml`）。松开即回到 1 倍。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('drama_card_gestures'))),
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
}
