import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_comment_panel.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 横屏布局只看窗口宽高（设备横置即横屏，不再跟着 `_fullScreen` 走），
    // 测试默认窗口 800×600 会被判成横屏。这里的用例按手机竖屏写，统一把
    // 视口钉成 360×800；要横屏的用例自己调 [_enterLandscape]。
    final view = binding.platformDispatcher.views.first;
    view.physicalSize = const Size(360, 800);
    view.devicePixelRatio = 1;
    SharedPreferences.setMockInitialValues({});
    // 面板交互用例钉住深色分支（play_control_panel_style_v681.style=1）。
    PlayerStyleConfig.instance = const PlayerStyleConfig(
      useNewPlayerBottomStyle: true,
      morePanelStyle: 1,
    );
  });
  tearDown(() {
    PlayerStyleConfig.instance = PlayerStyleConfig.defaults;
    final view = binding.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('anonymous comments expose no unavailable editor', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletCommentPanel(
            seriesId: 'series-1',
            loader:
                ({
                  required sort,
                  required count,
                  required cursor,
                  required tag,
                }) async => const PlayletCommentPage(
                  comments: [PlayletComment(id: 'c1', text: '这集好看')],
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('这集好看'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('发布'), findsNothing);
  });

  testWidgets('disabling the lock config restores controls while locked', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    var lockEnabled = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _chrome(player, lockEnabled: lockEnabled);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    await tester.tap(find.byKey(const ValueKey('landscape-lock')));
    await tester.pump();
    expect(find.byKey(const ValueKey('landscape-play')), findsNothing);

    update(() => lockEnabled = false);
    await tester.pump();
    expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
    expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('disabling clear screen cannot strand an empty player', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    var reverse = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _chrome(player, reverse: reverse);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    expect(find.text('恢复'), findsOneWidget);
    update(() => reverse = true);
    await tester.pump();
    expect(find.byKey(const ValueKey('player-catalog-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-clear-screen')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
  testWidgets('a single tap within 800ms of a double tap cannot pause', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    final point = tester.getCenter(find.byKey(const ValueKey('video-surface')));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // 短剧横屏双击：中间三分之一切播放（实测反馈：双击中间应暂停）。
  testWidgets('landscape double tap in the center third toggles playback', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    final point = tester.getCenter(find.byKey(const ValueKey('video-surface')));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // 短剧横屏双击：左/右三分之一 ±10s，不切播放。
  testWidgets('landscape double tap on the side thirds seeks by 10s', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final left = Offset(surface.left + surface.width / 6, surface.center.dy);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), isEmpty);
    expect(player.calls, contains('seek:10'));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('landscape double tap on the right third seeks forward 10s', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final right = Offset(surface.right - surface.width / 6, surface.center.dy);
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), isEmpty);
    expect(player.calls, contains('seek:30'));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // P1-11：暂停态侧边双击只 seek，不恢复播放（两个方向都不切播放态）。
  testWidgets('paused side double taps seek without resuming playback', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = false;
    await tester.pumpWidget(MaterialApp(home: _chrome(player, playing: false)));
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final left = Offset(surface.left + surface.width / 6, surface.center.dy);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    final right = Offset(surface.right - surface.width / 6, surface.center.dy);
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'play'), isEmpty);
    expect(player.calls.where((call) => call == 'pause'), isEmpty);
    expect(player.calls, contains('seek:10'));
    expect(player.calls, contains('seek:20'));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // P1-11：钳制——位置 0 左双击钳到 0，近终点右双击钳到 duration。
  testWidgets('side double taps clamp to 0 and to the duration', (
    tester,
  ) async {
    final atStart = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      MaterialApp(home: _chrome(atStart, initialPosition: Duration.zero)),
    );
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    var surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final left = Offset(surface.left + surface.width / 6, surface.center.dy);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    expect(atStart.calls, contains('seek:0'));
    await tester.pumpWidget(const SizedBox.shrink());
    await atStart.dispose();

    final nearEnd = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      MaterialApp(
        home: _chrome(
          nearEnd,
          duration: const Duration(seconds: 120),
          initialPosition: const Duration(seconds: 115),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final right = Offset(surface.right - surface.width / 6, surface.center.dy);
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 400));
    expect(nearEnd.calls, contains('seek:120'));
    await tester.pumpWidget(const SizedBox.shrink());
    await nearEnd.dispose();
  });

  // P1-11：duration==0 时侧边双击不 seek、不上报。
  testWidgets('zero duration blocks side double-tap seeks', (tester) async {
    final player = FakeNativePlayer()..isPlaying = true;
    final seeked = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: _chrome(player, duration: Duration.zero, onSeeked: seeked.add),
      ),
    );
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final left = Offset(surface.left + surface.width / 6, surface.center.dy);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    final right = Offset(surface.right - surface.width / 6, surface.center.dy);
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call.startsWith('seek:')), isEmpty);
    expect(seeked, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // P1-11：dx 恰好落在三分线上的双击走中间分支（切播放），不 seek。
  testWidgets('double taps exactly on the third boundaries toggle playback', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final third = surface.width / 3;
    final onLeftEdge = Offset(surface.left + third, surface.center.dy);
    await tester.tapAt(onLeftEdge);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(onLeftEdge);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), hasLength(1));
    expect(player.calls.where((call) => call.startsWith('seek:')), isEmpty);
    // 第二个边界点同样走中间分支：_chrome 的 playing 是静态 true，
    // 所以第二次双击仍是 pause（不是 play），关键是两次都不 seek。
    final onRightEdge = Offset(surface.right - third, surface.center.dy);
    await tester.tapAt(onRightEdge);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(onRightEdge);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), hasLength(2));
    expect(player.calls.where((call) => call.startsWith('seek:')), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // P1-11：未就绪时侧边双击不发 onSeeked、不写 _pendingSeek；
  // 就绪后一次有效双击仍按真实位置算目标（不被脏 pending 污染）。
  testWidgets('not-ready side double taps report nothing and poison nothing', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    final seeked = <Duration>[];
    var enabled = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _chrome(player, enabled: enabled, onSeeked: seeked.add);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final left = Offset(surface.left + surface.width / 6, surface.center.dy);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call.startsWith('seek:')), isEmpty);
    expect(seeked, isEmpty);

    update(() => enabled = true);
    await tester.pump();
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls, contains('seek:10'));
    expect(seeked, [const Duration(seconds: 10)]);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // P2-21：显式设 currentPosition/totalDuration；接 onSeeked 断言连续
  // 双击累积目标。native seek 被 gate 卡住时第二次双击必须基于
  // _pendingSeek 累积（40→30），而不是已确认位置（50）重算。
  testWidgets('consecutive side double taps accumulate via onSeeked', (
    tester,
  ) async {
    final seekGate = Completer<void>();
    final player = ControlledNativePlayer(seekGate: seekGate)..isPlaying = true;
    await player.create('https://example.invalid/1.mp4', '');
    final seeked = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: _chrome(
          player,
          duration: const Duration(seconds: 120),
          initialPosition: const Duration(seconds: 50),
          onSeeked: seeked.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final left = Offset(surface.left + surface.width / 6, surface.center.dy);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    expect(seeked, [const Duration(seconds: 40), const Duration(seconds: 30)]);
    seekGate.complete();
    await tester.pump();
    expect(
      player.calls.where((call) => call.startsWith('seek:')),
      containsAll(['seek:40000ms', 'seek:30000ms']),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // P2-22：清屏态双击（侧边与中间）既不 pause 也不 seek。
  testWidgets('double taps in clear screen issue no pause or seek', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    await _enterLandscape(tester);
    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('清屏播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // 清屏已进：横屏底条随 showChrome 一起隐藏。
    expect(find.byKey(const ValueKey('landscape-play')), findsNothing);
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final left = Offset(surface.left + surface.width / 6, surface.center.dy);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    final center = tester.getCenter(
      find.byKey(const ValueKey('video-surface')),
    );
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), isEmpty);
    expect(player.calls.where((call) => call == 'play'), isEmpty);
    expect(player.calls.where((call) => call.startsWith('seek:')), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // P1-11 + P2-1：控制条已自动隐藏时侧边双击仍 seek，并把控制条亮起。
  testWidgets('side double tap while controls are hidden seeks and reveals', (
    tester,
  ) async {
    // 全屏切换后的 _scheduleHide 在 await _applySystemUi() 之后；
    // 测试里 flutter/platform 无应答会挂住这条链，先 mock 成空应答。
    // 注意：SystemChannels.platform 用 JSONMethodCodec，不是默认编解码。
    const platformChannel = MethodChannel(
      'flutter/platform',
      JSONMethodCodec(),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      platformChannel,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        platformChannel,
        null,
      ),
    );
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    // 全屏切换的 _scheduleHide 在 await _applySystemUi() 之后：零时长 pump
    // 冲刷异步链但不推进假时钟，让 3s 隐藏计时器先排上。
    await _enterLandscape(tester);
    expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('landscape-play')), findsNothing);
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final left = Offset(surface.left + surface.width / 6, surface.center.dy);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls, contains('seek:10'));
    expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  // 官方长按两分支（jq3/x.java:2250-2252 + K6():2690-2711）：横向中心带
  // （竖屏 50%）内打开更多面板（y7 的 show_more_panel_from_long_click），
  // 带外才进 2x 倍速覆盖层。
  testWidgets('long press in the center band opens the more panel', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    await tester.longPressAt(
      tester.getCenter(find.byKey(const ValueKey('video-surface'))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-panel')), findsOneWidget);
    // 只允许初始的速率同步（rate:1.0），不允许长按倍速（rate:2.0）。
    expect(
      player.calls.where((call) => call.startsWith('rate:')),
      everyElement('rate:1.0'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('long press outside the center band boosts to 2x', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    await tester.longPressAt(Offset(surface.left + 12, surface.center.dy));
    expect(player.calls, contains('rate:2.0'));
    // 松开恢复原速（官方 g.k() 的 d(true) 行为）。
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.calls, contains('rate:1.0'));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets(
    'lock timeout requires waking the button and preserves video crop',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(
        MaterialApp(
          home: _chrome(
            player,
            lockEnabled: true,
            fillScreen: true,
            showSeekHint: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _enterLandscape(tester);
      final frame = tester.getRect(find.byKey(const ValueKey('video-frame')));
      final lock = find.byKey(const ValueKey('landscape-lock'));
      final position = tester.getRect(lock).center;
      await tester.tap(lock);
      await tester.pump(const Duration(seconds: 6));
      expect(tester.getRect(find.byKey(const ValueKey('video-frame'))), frame);
      expect(find.text('左右滑动可调整进度'), findsNothing);
      expect(lock.hitTestable(), findsNothing);
      await tester.tapAt(position);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('landscape-play')), findsNothing);
      expect(lock.hitTestable(), findsOneWidget);
      await tester.tap(lock);
      await tester.pump();
      expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets('external overlays end long press and block playback taps', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    var blocked = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _chrome(player, blocked: blocked);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 中心带内的长按现在打开更多面板（官方 y7 链路），倍速要压在带外。
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));
    final point = Offset(surface.left + 12, surface.center.dy);
    final gesture = await tester.startGesture(point);
    await tester.pump(const Duration(milliseconds: 700));
    expect(player.rate, 2);
    update(() => blocked = true);
    await tester.pump();
    expect(player.rate, 1);
    await gesture.up();
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('landscape panels hide the lock until they close', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      MaterialApp(home: _chrome(player, lockEnabled: true)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _enterLandscape(tester);
    await tester.tap(find.byKey(const ValueKey('landscape-episodes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('landscape-lock')), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('landscape-lock')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets(
    'legacy phone has only speed while pad has the icon clear action',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(
        MaterialApp(home: _chrome(player, newStyle: false)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('player-legacy-actions')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-clear-screen')), findsNothing);
      await tester.pumpWidget(
        MaterialApp(home: _chrome(player, newStyle: false, padStyle: true)),
      );
      await tester.pump();
      // o.W7：旧底栏（含 pad 分支）进页即清屏，栏内项直接亮「还原」；
      // 点「还原」回正常画面。
      expect(find.text('还原'), findsOneWidget);
      await tester.tap(find.text('还原'));
      await tester.pump();
      expect(find.byKey(const ValueKey('player-catalog-bar')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );
}

/// 点「全屏观看」再把窗口转成横屏：横屏布局只按窗口宽高判定，光点按钮
/// 不会改视口。
Future<void> _enterLandscape(WidgetTester tester) async {
  // 同一个用例可能连开两台播放器：先放回竖屏，「全屏观看」入口才会在场。
  await tester.binding.setSurfaceSize(null);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
  await tester.pump();
  await tester.binding.setSurfaceSize(const Size(800, 600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pump();
}

Widget _chrome(
  FakeNativePlayer player, {
  bool lockEnabled = false,
  bool reverse = false,
  bool blocked = false,
  bool fillScreen = false,
  bool showSeekHint = false,
  bool newStyle = true,
  bool padStyle = false,
  Duration duration = const Duration(minutes: 2),
  Duration? initialPosition,
  void Function(Duration target)? onSeeked,
  bool playing = true,
  bool enabled = true,
}) {
  // 显式钉住 Fake 的起点与总长：用例不隐式依赖 Fake 的默认 20s / 2min。
  player.totalDuration = duration;
  if (initialPosition != null) player.currentPosition = initialPosition;
  return VideoPlayerChrome(
    player: player,
    title: '剧',
    episodes: [
      Chapter(itemId: 'v1', title: '第一集', volumeName: ''),
      Chapter(itemId: 'v2', title: '第二集', volumeName: ''),
    ],
    currentIndex: 0,
    duration: duration,
    playing: playing,
    enabled: enabled,
    shortSeries: true,
    landscapeLockEnabled: lockEnabled,
    interactionBlocked: blocked,
    fillScreen: fillScreen,
    showSeekHint: showSeekHint,
    newPlayerBottomStyle: newStyle,
    padNewBottomStyle: padStyle,
    reverseClearScreen: reverse,
    onSeeked: onSeeked,
    onSelectEpisode: (_) async {},
    onError: (error) => throw error,
    child: const ColoredBox(color: Colors.black),
  );
}
