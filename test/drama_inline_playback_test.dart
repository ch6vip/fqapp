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

/// A notifier whose stream answers with `perTab` items per tab_type, so the feed
/// can be driven without the backend. `_forceKind` turns the 漫剧 tab's items
/// into `manju`, exactly like the real provider.
HomeNotifier _notifier({int perTab = 4}) => HomeNotifier(
  initialTabIndex: dramaTabIndex,
  homepageLoader: ({int tabType = 2, int offset = 0, String? sessionId}) async {
    return HomepagePage(
      items: [for (var index = 0; index < perTab; index++) _item('$tabType-$index')],
      nextOffset: null,
      sessionId: null,
    );
  },
  searchLoader: (query, {int page = 1}) async => const [],
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

  Widget app({bool tickerEnabled = true}) => ProviderScope(
    overrides: [
      homeProvider.overrideWith(() => _notifier()),
      dramaProvider.overrideWith(() => _notifier()),
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
    await SwipeGuideStore.instance.init();
    await SwipeGuideStore.instance.markShown();
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

    expect(session.directoryCalls, ['8-0:短剧']);
    expect(session.players, hasLength(1));
    final player = session.players.single;
    expect(player.calls.where((call) => call.startsWith('create:')), [
      'create:https://example.invalid/8-0-1.mp4',
    ]);
    expect(player.calls.where((call) => call == 'play'), ['play']);
    expect(player.playbackRequested, isTrue);

    // Exactly one texture, owned by the on-screen card.
    expect(find.byType(Texture), findsOneWidget);
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_8-0')),
      findsOneWidget,
    );
    // `create` completing is not a frame: the cover stays in front.
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_8-0')),
      findsOneWidget,
    );

    player.emitFirstFrame();
    await _flush(tester);
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_8-0')),
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
      find.byKey(const ValueKey('drama_inline_texture_video_8-0')),
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
      find.byKey(const ValueKey('drama_inline_texture_video_8-0')),
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
              const ValueKey('drama_inline_texture_video_8-0'),
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
    expect(second.calls, contains('create:https://example.invalid/8-1-1.mp4'));
    expect(second.isPlaying, isTrue);

    // 只有屏幕上那张卡挂纹理。
    expect(find.byType(Texture), findsOneWidget);
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_8-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_8-0')),
      findsNothing,
    );
    expect(find.text('8-1 作品'), findsOneWidget);
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
      find.byKey(const ValueKey('drama_inline_texture_video_8-0')),
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
      find.byKey(const ValueKey('drama_inline_texture_video_8-0')),
      findsOneWidget,
    );

    await _swipeUp(tester);

    // 第 2 张卡拿到纹理，且它的封面已经被首帧替换掉。
    expect(
      find.byKey(const ValueKey('drama_inline_texture_video_8-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_8-1')),
      findsNothing,
    );
    expect(find.byType(Texture), findsOneWidget);

    // 第 1 张卡不再持有任何视频层。
    expect(
      find.byKey(const ValueKey('drama_inline_cover_video_8-0')),
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
      find.byKey(const ValueKey('drama_inline_texture_video_8-0')),
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
      find.byKey(const ValueKey('drama_inline_cover_video_8-0')),
      findsOneWidget,
    );
    expect(find.text('网络异常，请稍后再试'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('drama_inline_retry_video_8-0')),
      findsOneWidget,
    );

    expect(tester.takeException(), isNull);

    final callsBefore = session.contentCalls.length;
    await tester.tap(
      find.byKey(const ValueKey('drama_inline_retry_video_8-0')),
    );
    await _flush(tester);
    expect(session.contentCalls.length, greaterThan(callsBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('静音起播、长按 2 倍速、进度条可拖动', (tester) async {
    final session = _Session(hasFirstFrame: true);
    await _mount(tester, session);
    // 进度条只在拿到时长后才出现（`cjt.xml` 的 16dp 条随 duration 走）。
    session.players.single.emitDuration(const Duration(minutes: 2));
    await _flush(tester);
    // 官方的自动播放是静音的，并给出「取消静音」提示（`ck8.xml` / `@string/e8d`）。
    expect(session.players.single.calls, contains('volume:0.0'));
    expect(find.byKey(const Key('drama_mute_hint')), findsOneWidget);
    expect(find.text('取消静音'), findsOneWidget);
    // 点它开启声音：音量置 1，短暂显示「已开启声音」(`@string/e8k`)。
    await tester.tap(find.byKey(const Key('drama_mute_hint')));
    await _flush(tester);
    expect(session.players.single.calls, contains('volume:1.0'));
    expect(find.text('已开启声音'), findsOneWidget);


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
}
