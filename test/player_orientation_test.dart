import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/player_layout_preferences.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

/// Records the orientation requests the player makes.
class _OrientationLog {
  final List<List<String>> requests = [];

  /// The most recent request, or null when none was made.
  List<String>? get last => requests.isEmpty ? null : requests.last;

  bool get pinnedPortraitOnly =>
      last != null &&
      last!.isNotEmpty &&
      last!.every((value) => value.startsWith('DeviceOrientation.portrait'));

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          final arguments = call.arguments;
          if (arguments is List) {
            requests.add(arguments.map((value) => '$value').toList());
          }
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'player_playback_rate': 1.0}),
  );

  testWidgets('an episode change never forces portrait', (tester) async {
    // The reported bug: playing a landscape episode fullscreen, the next
    // episode auto-plays and the picture snaps back to portrait. The new player
    // reports no video size yet, and "0 > 0 is false, so portrait" was the
    // cause.
    final orientations = _OrientationLog()..install(tester);
    final first = FakeNativePlayer(width: 1920, height: 1080);
    final second = FakeNativePlayer(width: 0, height: 0);

    await tester.pumpWidget(_app(first));
    await tester.pumpAndSettle();

    // Go fullscreen: a known landscape video pins landscape.
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    expect(orientations.last, isNotNull);
    expect(orientations.pinnedPortraitOnly, isFalse);

    // Auto-advance hands over to a freshly created player of unknown size.
    await tester.pumpWidget(_app(second));
    await tester.pumpAndSettle();
    expect(
      orientations.pinnedPortraitOnly,
      isFalse,
      reason: 'an unknown video size must not be read as portrait',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await first.dispose();
    await second.dispose();
  });

  testWidgets(
    'an unknown size leaves the orientation alone, and a late size changes nothing',
    (tester) async {
      final orientations = _OrientationLog()..install(tester);
      // Starts unknown, exactly like a player created for the next episode.
      final player = FakeNativePlayer(width: 0, height: 0);

      await tester.pumpWidget(_app(player));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      // 尺寸未知时不发方向请求：沿用当前方向，连播切集不会突然翻一下（#59）。
      expect(orientations.requests, isEmpty);

      // 尺寸到达后也不会补发：全屏形态已经定了，中途转向等于闪一下。
      player.width = 1920;
      player.height = 1080;
      await tester.pumpWidget(_app(player));
      await tester.pumpAndSettle();
      expect(orientations.requests, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets('a portrait fullscreen survives the next episode (#59)', (
    tester,
  ) async {
    // 竖版短剧全屏连播下一集：新播放器尺寸未知，不能因为「未知」就把竖屏
    // 翻成横屏。
    final orientations = _OrientationLog()..install(tester);
    final first = FakeNativePlayer(width: 1080, height: 1920);
    final second = FakeNativePlayer(width: 0, height: 0);

    await tester.pumpWidget(_app(first));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);

    await tester.pumpWidget(_app(second));
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);

    await tester.pumpWidget(const SizedBox.shrink());
    await first.dispose();
    await second.dispose();
  });

  testWidgets('a portrait video goes fullscreen in portrait', (tester) async {
    // 竖版片源（短剧主流的 9:16）点「全屏」应铺满竖屏：此前全屏一律请求
    // landscape，竖剧进全屏被转成横屏，画面两侧留大片黑边。
    final orientations = _OrientationLog()..install(tester);
    final player = FakeNativePlayer(width: 1080, height: 1920);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('the feed landscape entry keeps landscape for a portrait video', (
    tester,
  ) async {
    // feed 卡片右侧那颗钮的语义就是「横屏观看」，竖版片源也一样。
    final orientations = _OrientationLog()..install(tester);
    final player = FakeNativePlayer(width: 1080, height: 1920);

    await tester.pumpWidget(_app(player, openFullScreen: true));
    await tester.pumpAndSettle();
    expect(orientations.last, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('the feed entry only forces landscape for the first fullscreen', (
    tester,
  ) async {
    // `openFullScreen` 是整页的入场标记，恒为 true。拿它当方向判据的话，
    // 从 feed 横屏钮进来的竖版片源会永远被锁成横屏——退出再点「全屏观看」
    // 也不会铺满竖屏。
    final orientations = _OrientationLog()..install(tester);
    await tester.binding.setSurfaceSize(const Size(400, 888));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = FakeNativePlayer(width: 1080, height: 1920);

    await tester.pumpWidget(_app(player, openFullScreen: true));
    await tester.pumpAndSettle();
    expect(orientations.last, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);

    // 通用播放器竖屏全屏的出口是运输条自带的「退出全屏」：贴底胶囊只给
    // 短剧，否则同屏两个等价出口（详看 video_player_chrome 里的那条门）。
    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();

    // 之后的全屏按片源算：竖版片源铺满竖屏。退出全屏必须把控件带回来，
    // 否则这一步找不到「全屏观看」入口。
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);

    // 走完收起计时，避免留下 pending timer。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('leaving a hidden-chrome fullscreen brings the controls back', (
    tester,
  ) async {
    // 竖屏全屏会让控件 3 秒收起。此时按系统返回回到浏览态，`_scheduleHide`
    // 的常驻分支不再排计时：`_visible` 停在 false 的话，顶栏、右栏与
    // 「全屏观看」入口全都不渲染，只剩剧名/选集条，而且没有再次进全屏的路。
    await tester.binding.setSurfaceSize(const Size(400, 888));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = FakeNativePlayer(width: 1080, height: 1920)
      ..isPlaying = true;
    await tester.pumpWidget(_app(player, shortSeries: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    // 全屏控件 3 秒后收起。
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('player-fullscreen-pill')), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-fullscreen-pill')),
      findsOneWidget,
    );
    expect(find.byTooltip('返回'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('auto split survives an episode handoff with no size yet', (
    tester,
  ) async {
    // 连播切集：新的播放器要先建出来，尺寸要等首帧到达。未知尺寸按横版
    // 占位（分屏本就是给横版片源用的），横版剧换集时不再整块收起再展开。
    await tester.binding.setSurfaceSize(const Size(407, 904));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final first = FakeNativePlayer(width: 1920, height: 1080)..isPlaying = true;
    await tester.pumpWidget(
      _app(
        first,
        shortSeries: true,
        mode: PlayerLayoutMode.auto,
        withSplit: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-split-stage')), findsOneWidget);

    // 同一个 chrome（State 不变），换上下一个尺寸未知的播放器。
    final next = FakeNativePlayer(width: 0, height: 0)..isPlaying = true;
    await tester.pumpWidget(
      _app(
        next,
        shortSeries: true,
        mode: PlayerLayoutMode.auto,
        withSplit: true,
      ),
    );
    expect(find.byKey(const ValueKey('player-split-stage')), findsOneWidget);

    // 首帧到达、尺寸补齐后仍是分屏。
    next.width = 1920;
    next.height = 1080;
    await tester.pumpWidget(
      _app(
        next,
        shortSeries: true,
        mode: PlayerLayoutMode.auto,
        withSplit: true,
      ),
    );
    expect(find.byKey(const ValueKey('player-split-stage')), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await first.dispose();
    await next.dispose();
  });

  testWidgets('the split top bar stays dark under a light theme', (
    tester,
  ) async {
    // 状态栏那条与视频同色：浅色主题的画布是 #F6F6F6，压在黑视频上会
    // 露出一条白边；B 站播放页顶部是深底白图标。只改这一条，面板仍是
    // 浅色画布，所以图标必须跟着转白。
    final player = FakeNativePlayer(width: 1080, height: 1920);
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        mode: PlayerLayoutMode.split,
        withSplit: true,
        padding: const EdgeInsets.only(top: 39, bottom: 16),
      ),
    );
    await tester.pumpAndSettle();
    final bar = find.descendant(
      of: find.byKey(const ValueKey('player-split-status-bar')),
      matching: find.byType(ColoredBox),
    );
    expect(tester.getSize(bar).height, 39);
    expect(tester.widget<ColoredBox>(bar).color, Colors.black);
    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('player-split-status-bar')),
            matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          )
          .first,
    );
    expect(region.value.statusBarIconBrightness, Brightness.light);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('leaving fullscreen releases the orientation', (tester) async {
    final orientations = _OrientationLog()..install(tester);
    final player = FakeNativePlayer(width: 1920, height: 1080);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    // An empty list means "follow the device again".
    expect(orientations.last, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('back leaves fullscreen and pins the window to portrait', (
    tester,
  ) async {
    // 返回键的语义是「退出横屏、回到原来的竖屏页」。只放开朝向的话，仍横握
    // 的设备会立刻转回横屏，看起来像「按返回反而进了横屏选集」。
    final orientations = _OrientationLog()..install(tester);
    final player = FakeNativePlayer(width: 1920, height: 1080);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    expect(orientations.pinnedPortraitOnly, isFalse);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);

    // 退出播放页要放开这把竖屏锁，后面的页面不能跟着被锁住。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(orientations.last, isEmpty);
    await player.dispose();
  });

  testWidgets(
    'a portrait fullscreen has no lock and rotation releases a landscape lock',
    (tester) async {
      // 锁是横屏形态件：竖屏全屏不该有；横屏锁了之后再转回竖屏，锁必须自己
      // 释放，且目录件（剧名/热评/选集条）不能跟着回来（issue #59）。
      final player = FakeNativePlayer()..isPlaying = true;
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pumpWidget(
        _app(player, shortSeries: true, landscapeLock: true),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);

      await tester.binding.setSurfaceSize(const Size(800, 450));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('landscape-lock')));
      await tester.pump();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
      expect(find.byKey(const ValueKey('player-catalog-bar')), findsNothing);
      expect(find.text('退出全屏'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets('pushing another route suspends the portrait pin', (
    tester,
  ) async {
    // 竖屏钉是引擎级的：不随路由释放的话，从分屏面板 push 的详情 / 听剧页
    // 会一直被锁在竖屏，直到播放页被 pop。
    final orientations = _OrientationLog()..install(tester);
    final player = FakeNativePlayer(width: 1920, height: 1080);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);

    final navigator = Navigator.of(
      tester.element(find.byType(VideoPlayerChrome)),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('详情')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('详情'), findsOneWidget);
    expect(orientations.last, isEmpty);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(orientations.last, isEmpty);
    await player.dispose();
  });
}

Widget _app(
  FakeNativePlayer player, {
  bool openFullScreen = false,
  bool shortSeries = false,
  PlayerLayoutMode mode = PlayerLayoutMode.immersive,
  bool withSplit = false,
  bool landscapeLock = false,
  EdgeInsets padding = EdgeInsets.zero,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(padding: padding),
    child: child!,
  ),
  home: VideoPlayerChrome(
    player: player,
    episodes: [
      Chapter(itemId: '1', title: '第一集', volumeName: ''),
      Chapter(itemId: '2', title: '第二集', volumeName: ''),
    ],
    currentIndex: 0,
    duration: player.duration,
    playing: true,
    shortSeries: shortSeries,
    openFullScreen: openFullScreen,
    landscapeLockEnabled: landscapeLock,
    layoutMode: mode,
    splitPanel: withSplit
        ? const ColoredBox(
            key: ValueKey('fake-split-panel'),
            color: Colors.blueGrey,
          )
        : null,
    onSelectEpisode: (index) async {},
    onError: (error) => throw error,
    child: const ColoredBox(color: Colors.black),
  ),
);
