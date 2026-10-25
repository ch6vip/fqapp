import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/services/player_layout_preferences.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_layer.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5}),
  );

  Future<FakeNativePlayer> mount(
    WidgetTester tester, {
    Size window = const Size(407, 904),
    EdgeInsets padding = const EdgeInsets.only(top: 39, bottom: 16),
    Size videoSize = const Size(1080, 1920),
    PlayerLayoutMode mode = PlayerLayoutMode.split,
    bool withPanel = true,
    List<PlayletComment> danmaku = const [],
  }) async {
    await tester.binding.setSurfaceSize(window);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // setSurfaceSize 只改渲染尺寸，MediaQuery 仍是 800x600；弹幕的横竖屏
    // 判据读设备朝向，必须让两者一致。
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final player = FakeNativePlayer(
      width: videoSize.width.toInt(),
      height: videoSize.height.toInt(),
    )..isPlaying = true;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: padding),
          child: child!,
        ),
        home: VideoPlayerChrome(
          player: player,
          title: '测试短剧',
          episodes: List.generate(
            12,
            (index) => Chapter(
              itemId: '${index + 1}',
              title: '第${index + 1}集',
              volumeName: '',
            ),
          ),
          currentIndex: 0,
          playingIndex: 0,
          playing: true,
          duration: player.duration,
          shortSeries: true,
          layoutMode: mode,
          danmaku: danmaku,
          danmakuEnabled: danmaku.isNotEmpty,
          splitPanel: withPanel
              ? const ColoredBox(
                  key: ValueKey('fake-split-panel'),
                  color: Colors.blueGrey,
                )
              : null,
          onSelectEpisode: (index) async {},
          onError: (error) => throw error,
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return player;
  }

  Future<void> revealControls(WidgetTester tester) async {
    if (find.byKey(const ValueKey('compact-play')).evaluate().isNotEmpty) {
      return;
    }
    await tester.tap(find.byKey(const ValueKey('video-surface')));
    await tester.pump();
  }

  /// 手势通道替身：`levels == null` 模拟原生读不到档位（Activity 未附着）。
  void mockGestureChannel(
    WidgetTester tester,
    List<MethodCall> calls, {
    Map<String, Object?>? levels,
  }) {
    const channel = MethodChannel('fqapp/native_player');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'gestureLevels') return levels;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  /// 分屏提示与手势 HUD 都有自动隐藏定时器；测试结束前必须走完，否则
  /// Flutter 会报「A Timer is still pending」。
  Future<void> drainTimers(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 4));

  double pagerPage(WidgetTester tester) {
    final pager = tester.widget<PageView>(
      find.byKey(const ValueKey('episode-pager')),
    );
    return pager.controller!.page!;
  }

  testWidgets('分屏里倍速入口只剩紧凑条一处', (tester) async {
    // 分屏视频盒有自己的紧凑条（`compact-rate` 已显示当前档）；视频设置
    // 面板里不能再给倍速/清晰度入口行，否则又是「同一件事两个入口」。
    final original = PlayerStyleConfig.instance;
    PlayerStyleConfig.instance = const PlayerStyleConfig(morePanelStyle: 1);
    addTearDown(() => PlayerStyleConfig.instance = original);

    await mount(tester);
    await revealControls(tester);
    // 打开面板前：紧凑条上已经显示当前档。
    expect(find.byKey(const ValueKey('compact-rate')), findsOneWidget);

    // 中带长按打开视频设置（打开期间底栏让位，`showChrome` 为假）。
    await tester.longPress(find.byKey(const ValueKey('video-surface')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('compact-rate')), findsNothing);
    // 面板里不能再补一行倍速/清晰度——全页入口始终只有紧凑条那一处。
    expect(find.byKey(const ValueKey('player-more-rate-row')), findsNothing);
    expect(find.byKey(const ValueKey('player-more-quality-row')), findsNothing);
    await drainTimers(tester);
  });

  testWidgets('portrait split puts the panel under a full-width video box', (
    tester,
  ) async {
    await mount(tester);
    final stage = tester.getRect(
      find.byKey(const ValueKey('player-split-stage')),
    );
    expect(stage.width, 407);
    expect(stage.top, 39);
    // 竖屏片源：上半区取可用高度的 42%。
    expect(stage.height, closeTo((904 - 55) * .42, 1));
    expect(
      tester.getRect(find.byKey(const ValueKey('fake-split-panel'))).top,
      // 视频盒与面板之间是 18 高的可拖动分隔条。
      closeTo(stage.bottom + 18, .5),
    );

    // 视频盒里画面完整显示（contain），不被上半区裁切。
    final video = tester.getRect(find.byKey(const ValueKey('video-frame')));
    expect(video.height, closeTo(stage.height, .5));
    expect(video.width, closeTo(stage.height * 9 / 16, 1));

    // 竖屏提示指「下方」，并说明分隔条可拖动。
    expect(find.text('下方左右滑切换简介 / 评论 · 拖分隔条调比例'), findsOneWidget);
    await revealControls(tester);
    expect(find.byKey(const ValueKey('compact-seek')), findsOneWidget);
    expect(find.byKey(const ValueKey('compact-time')), findsOneWidget);
    expect(find.byKey(const ValueKey('compact-total-time')), findsOneWidget);
    expect(find.byKey(const ValueKey('compact-fullscreen')), findsOneWidget);
    // 竖屏整屏形态的选集条/右栏/底部信息层都不在分屏盒子里。
    expect(find.byKey(const ValueKey('player-catalog-bar')), findsNothing);
    expect(find.byKey(const ValueKey('player-comment-button')), findsNothing);
    expect(tester.takeException(), isNull);
    await drainTimers(tester);
  });

  testWidgets('compact bar toggles playback through the player', (
    tester,
  ) async {
    final player = await mount(tester);
    await revealControls(tester);
    player.calls.clear();
    await tester.tap(find.byKey(const ValueKey('compact-play')));
    await tester.pump();
    expect(player.calls, contains('pause'));
    await drainTimers(tester);
  });

  testWidgets('fullscreen leaves the split and returns to the full stage', (
    tester,
  ) async {
    await mount(tester);
    await revealControls(tester);
    await tester.tap(find.byKey(const ValueKey('compact-fullscreen')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);
    expect(find.byKey(const ValueKey('fake-split-panel')), findsNothing);
    expect(find.byKey(const ValueKey('video-surface')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the full stage keeps the pager on the current episode', (
    tester,
  ) async {
    // 分屏 ↔ 整屏会重建 PageView，新 pager 从 initialPage 起算。不同步的话
    // 画面停在进入集，声音已经播到当前集——用户看到的就是「只有封面」。
    await tester.binding.setSurfaceSize(const Size(407, 904));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.physicalSize = const Size(407, 904);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final player = FakeNativePlayer(width: 1080, height: 1920)
      ..isPlaying = true;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
    var index = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return VideoPlayerChrome(
              player: player,
              title: '测试短剧',
              episodes: List.generate(
                6,
                (i) => Chapter(
                  itemId: '${i + 1}',
                  title: '第${i + 1}集',
                  volumeName: '',
                ),
              ),
              currentIndex: index,
              playing: true,
              duration: player.duration,
              shortSeries: true,
              layoutMode: PlayerLayoutMode.split,
              splitPanel: const ColoredBox(
                key: ValueKey('fake-split-panel'),
                color: Colors.blueGrey,
              ),
              onSelectEpisode: (next) async => rebuild(() => index = next),
              onError: (error) => throw error,
              child: const ColoredBox(color: Colors.black),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(pagerPage(tester), 0);

    // 第 5 集：分屏视频盒换页。
    rebuild(() => index = 4);
    await tester.pumpAndSettle();
    expect(pagerPage(tester), 4);

    await revealControls(tester);
    await tester.tap(find.byKey(const ValueKey('compact-fullscreen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);
    expect(pagerPage(tester), 4);
    expect(find.byKey(const ValueKey('episode-page-4')), findsOneWidget);
    await drainTimers(tester);
  });

  testWidgets('the landscape full stage opens the right episode drawer', (
    tester,
  ) async {
    // 分屏模式的横屏全屏右下角是「选集」：与 B 站一致，在横屏里直接拉开
    // 右侧约 1/3 屏的选集抽屉，而不是退回竖屏的「简介 / 评论」分屏页。
    await mount(tester, window: const Size(900, 420), padding: EdgeInsets.zero);
    await revealControls(tester);
    await tester.tap(find.byKey(const ValueKey('compact-fullscreen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);
    expect(find.text('选集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('landscape-episodes')));
    // 200ms 滑入；抽屉里有循环 Lottie，固定时长 pump（勿 settle）。先起一帧
    // 让滑入动画开始，否则量到的矩形还带着入场位移。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('story-episode-drawer')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);
    final drawer = tester.getRect(
      find.byKey(const ValueKey('story-episode-drawer')),
    );
    // 与视频设置同一套宽度公式：(900 / 3) 落在 240..420 区间。
    expect(drawer.width, closeTo(300, .5));
    expect(drawer.right, closeTo(900, .5));
    await tester.tap(find.byKey(const ValueKey('story-drawer-close')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('story-episode-drawer')), findsNothing);
    await drainTimers(tester);
  });

  testWidgets('a landscape surface splits into left video and right panel', (
    tester,
  ) async {
    await mount(tester, window: const Size(900, 420), padding: EdgeInsets.zero);
    final stage = tester.getRect(
      find.byKey(const ValueKey('player-split-stage')),
    );
    // 900 宽：视频 558，右侧面板 342。
    expect(stage.width, closeTo(558, .5));
    expect(stage.height, 420);
    final panel = tester.getRect(
      find.byKey(const ValueKey('fake-split-panel')),
    );
    // 中间是 18 宽的可拖动分隔条，面板宽度相应少 18。
    expect(panel.left, closeTo(stage.right + 18, .5));
    expect(panel.width, closeTo(900 - 558 - 18, .5));
    expect(panel.height, 420);
    // 横屏分屏的下半区在右侧，提示不能再说「下方」。
    expect(find.text('右侧栏左右滑切换简介 / 评论 · 点分隔条收起'), findsOneWidget);
    await drainTimers(tester);
  });

  testWidgets('immersive mode ignores the split panel entirely', (
    tester,
  ) async {
    await mount(tester, mode: PlayerLayoutMode.immersive);
    expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);
    expect(find.byKey(const ValueKey('fake-split-panel')), findsNothing);
    expect(find.byKey(const ValueKey('video-frame')), findsOneWidget);
  });

  testWidgets('auto mode only splits portrait devices showing a wide source', (
    tester,
  ) async {
    await mount(
      tester,
      mode: PlayerLayoutMode.auto,
      videoSize: const Size(1920, 1080),
    );
    expect(find.byKey(const ValueKey('player-split-stage')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await mount(
      tester,
      mode: PlayerLayoutMode.auto,
      videoSize: const Size(1080, 1920),
    );
    expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await mount(
      tester,
      mode: PlayerLayoutMode.auto,
      videoSize: const Size(1920, 1080),
      window: const Size(900, 420),
      padding: EdgeInsets.zero,
    );
    // 设备本身横置时屏幕已经是宽的，不再左右拆。
    expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);
  });

  testWidgets('a landscape window hides the bar without entering fullscreen', (
    tester,
  ) async {
    // 设备横置（没点「全屏观看」）也是横屏形态：底条必须照常 3 秒收起，
    // 不能因为竖屏底栏「常驻」的早退分支一直压在画面上。
    await mount(
      tester,
      window: const Size(900, 420),
      padding: EdgeInsets.zero,
      mode: PlayerLayoutMode.immersive,
    );
    expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('landscape-play')), findsNothing);
  });

  testWidgets('a dragged ratio is dropped when the split axis changes', (
    tester,
  ) async {
    await mount(tester, padding: EdgeInsets.zero);
    final stage = find.byKey(const ValueKey('player-split-stage'));
    // 竖屏往上拖：视频盒变矮（比例落到约 0.30）。
    await tester.drag(
      find.byKey(const ValueKey('player-split-divider')),
      const Offset(0, -120),
    );
    await tester.pump();
    expect(tester.getRect(stage).height, lessThan(300));

    // 横过来：0.30 当成横屏宽度比例只剩两百多宽，必须回落到横屏默认值
    // （900 宽下左侧视频 558）。
    await tester.binding.setSurfaceSize(const Size(900, 420));
    tester.view.physicalSize = const Size(900, 420);
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle();
    expect(tester.getRect(stage).width, closeTo(558, .5));
    await drainTimers(tester);
  });

  testWidgets('a player without a split panel stays immersive', (tester) async {
    await mount(tester, withPanel: false);
    expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);
    expect(find.byKey(const ValueKey('video-frame')), findsOneWidget);
  });

  testWidgets('vertical swipes adjust brightness left and volume right', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('fqapp/native_player');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'gestureLevels') {
        return <String, double>{'brightness': .5, 'volume': .5};
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await mount(tester);
    // 起手档位在进入分屏时异步读取；读完之后再开始手势。
    await tester.pump();
    calls.clear();
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));

    // 左半区上滑：亮度升高，并出现亮度 HUD。第一次 move 只够越过
    // 触摸 slop 触发 onStart，真正产生位移需要第二次 move。
    var gesture = await tester.startGesture(
      surface.topLeft + Offset(surface.width * .25, surface.height * .6),
    );
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-gesture-label')))
          .data,
      '亮度',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-gesture-percent')))
          .data,
      isNot('50%'),
    );
    await gesture.up();
    await tester.pump();
    final brightness = calls.lastWhere(
      (call) => call.method == 'setScreenBrightness',
    );
    expect((brightness.arguments as Map)['value'], greaterThan(.5));

    // 右半区下滑：音量降低，HUD 换成音量。
    gesture = await tester.startGesture(
      surface.topLeft + Offset(surface.width * .75, surface.height * .4),
    );
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-gesture-label')))
          .data,
      '音量',
    );
    await gesture.up();
    await tester.pump();
    final volume = calls.lastWhere((call) => call.method == 'setMediaVolume');
    expect((volume.arguments as Map)['value'], lessThan(.5));

    // 离开播放页后还原窗口亮度，避免影响其它页面。多 pump 一段时间，
    // 让双击识别器的 40ms 倒计时在测试结束前走完。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls.map((call) => call.method), contains('resetScreenBrightness'));
  });

  testWidgets('volume HUD snaps to the device step count', (tester) async {
    final calls = <MethodCall>[];
    mockGestureChannel(
      tester,
      calls,
      levels: {'brightness': .5, 'volume': .5, 'volumeSteps': 160},
    );
    await mount(tester);
    await tester.pump();
    calls.clear();
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));

    final gesture = await tester.startGesture(
      surface.topLeft + Offset(surface.width * .75, surface.height * .5),
    );
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -70));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final volume = calls.lastWhere((call) => call.method == 'setMediaVolume');
    final value = (volume.arguments as Map)['value'] as double;
    // 本机 160 档：下发值必须落在 1/160 的整数倍上，HUD 才不会比实际
    // 音量多显示或少显示一档。
    expect(value * 160, closeTo((value * 160).roundToDouble(), .0001));
    // HUD 百分比必须能由下发值还原，不能出现「HUD 78%、系统 77%」。
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-gesture-percent')))
          .data,
      '${(value * 100).round()}%',
    );
    await drainTimers(tester);
  });

  testWidgets('a failed levels read shows the unavailable HUD', (tester) async {
    final calls = <MethodCall>[];
    mockGestureChannel(tester, calls);
    await mount(tester);
    await tester.pump();
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));

    final gesture = await tester.startGesture(
      surface.topLeft + Offset(surface.width * .25, surface.height * .5),
    );
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('player-gesture-unavailable')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-gesture-percent')))
          .data,
      '--',
    );
    await gesture.up();
    await tester.pump();
    // 「暂不可用」HUD 与分屏提示各有一个自动隐藏定时器。
    await drainTimers(tester);
  });

  testWidgets('the first split shows a one-time gesture hint', (tester) async {
    await mount(tester);
    await tester.pump();
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('player-split-hint')),
          )
          .opacity,
      1,
    );
    await tester.pump(const Duration(seconds: 4));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('player-split-hint')),
          )
          .opacity,
      0,
    );
  });

  testWidgets('the split divider resizes and collapses the panel', (
    tester,
  ) async {
    await mount(tester);
    final stage = find.byKey(const ValueKey('player-split-stage'));
    final before = tester.getRect(stage).height;

    // 分隔条向下拖：上方视频盒变高。
    await tester.drag(
      find.byKey(const ValueKey('player-split-divider')),
      const Offset(0, 120),
    );
    await tester.pump();
    expect(tester.getRect(stage).height, greaterThan(before + 80));

    // 点分隔条收起：视频盒占满可用高度，露出「选集」恢复按钮。
    await tester.tap(find.byKey(const ValueKey('player-split-divider')));
    await tester.pump();
    expect(find.byKey(const ValueKey('fake-split-panel')), findsNothing);
    expect(find.byKey(const ValueKey('player-split-expand')), findsOneWidget);
    expect(tester.getRect(stage).height, closeTo(904 - 55, .5));

    await tester.tap(find.byKey(const ValueKey('player-split-expand')));
    await tester.pump();
    expect(find.byKey(const ValueKey('fake-split-panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drainTimers(tester);
  });

  testWidgets('landscape can collapse the right panel and restore it', (
    tester,
  ) async {
    await mount(tester, window: const Size(900, 420), padding: EdgeInsets.zero);
    final stage = find.byKey(const ValueKey('player-split-stage'));
    expect(tester.getRect(stage).width, closeTo(558, .5));

    await tester.tap(find.byKey(const ValueKey('player-split-divider')));
    await tester.pump();
    expect(find.byKey(const ValueKey('fake-split-panel')), findsNothing);
    expect(tester.getRect(stage).width, 900);

    await tester.tap(find.byKey(const ValueKey('player-split-expand')));
    await tester.pump();
    expect(find.byKey(const ValueKey('fake-split-panel')), findsOneWidget);
    await drainTimers(tester);
  });

  testWidgets('portrait split keeps danmaku on the portrait timeline', (
    tester,
  ) async {
    await mount(
      tester,
      danmaku: const [PlayletComment(id: 'd1', text: '弹幕', offsetMs: 0)],
    );
    expect(find.byKey(const ValueKey('player-danmaku-layer')), findsOneWidget);
    // 视频盒是宽扁的 4:3 裁切，但设备竖屏：不能用盒子的宽高比判横屏，
    // 否则飞行时长与轨道密度都会按横屏走。
    final layer = tester.widget<PlayletDanmakuLayer>(
      find.byKey(const ValueKey('player-danmaku-layer')),
    );
    expect(layer.landscape, isFalse);
    await drainTimers(tester);
  });
}
