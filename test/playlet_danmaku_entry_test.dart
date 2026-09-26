import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_layer.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

/// 无账号模式保留弹幕开关与渲染，不显示发送入口。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget app({
    bool danmakuEnabled = true,
    VoidCallback? onToggle,
    List<PlayletComment> danmaku = const [],
    FakeNativePlayer? nativePlayer,
    bool enabled = true,
  }) {
    final player = nativePlayer ?? (FakeNativePlayer()..isPlaying = true);
    if (nativePlayer == null) addTearDown(player.dispose);
    return MaterialApp(
      home: Scaffold(
        body: VideoPlayerChrome(
          player: player,
          title: '剧',
          episodes: [Chapter(itemId: 'v1', title: '第一集', volumeName: '')],
          currentIndex: 0,
          duration: const Duration(minutes: 2),
          playing: player.playing,
          enabled: enabled,
          shortSeries: true,
          danmaku: danmaku,
          danmakuEnabled: danmakuEnabled,
          onToggleDanmaku: onToggle,
          onSelectEpisode: (_) async {},
          onError: (error) => throw error,
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );
  }

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
  }

  testWidgets('the more panel carries the danmaku switch', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(app(onToggle: () => toggles++));
    await tester.pumpAndSettle();
    await openMore(tester);
    expect(
      find.byKey(const ValueKey('player-more-danmaku-row')),
      findsOneWidget,
    );
    expect(find.text('弹幕'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-more-danmaku-switch')));
    await tester.pumpAndSettle();
    expect(toggles, 1);
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('player-more-danmaku-row')),
      ),
      matchesSemantics(
        label: '弹幕',
        hasToggledState: true,
        isToggled: false,
        hasTapAction: true,
      ),
    );
    expect(find.text('发弹幕'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('without a toggle callback the danmaku row is absent', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await openMore(tester);
    expect(find.byKey(const ValueKey('player-more-danmaku-row')), findsNothing);
    expect(
      find.byKey(const ValueKey('player-more-danmaku-send')),
      findsNothing,
    );
  });

  testWidgets('the danmaku layer renders only for short series', (
    tester,
  ) async {
    final entry = PlayletComment(
      id: 'd1',
      text: '前方高能',
      dataType: UgcRelativeType.seriesVideo,
      offsetMs: 15000,
    );
    await tester.pumpWidget(app(danmaku: [entry], onToggle: () {}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-danmaku-layer')), findsOneWidget);
    // 假播放器起播在 20s，弹幕时间点要落在飞行窗口内才会出现。
    expect(find.byKey(const ValueKey('danmaku-d1')), findsOneWidget);
  });

  const entry = PlayletComment(id: 'moving', text: '逐帧滚动', offsetMs: 15000);
  final moving = find.byKey(const ValueKey('danmaku-moving'));

  Future<void> portrait(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  }

  testWidgets(
    'playback state, buffering, background and readiness stop scrolling',
    (tester) async {
      await portrait(tester);
      final player = FakeNativePlayer()..isPlaying = true;
      addTearDown(player.dispose);
      Future<void> mount({bool enabled = true}) => tester.pumpWidget(
        app(nativePlayer: player, danmaku: const [entry], enabled: enabled),
      );
      Future<void> expectMoving() async {
        final before = tester.getTopLeft(moving);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(moving).dx, lessThan(before.dx));
      }

      Future<void> expectStopped() async {
        final before = tester.getTopLeft(moving);
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.getTopLeft(moving), before);
      }

      await mount();
      await tester.pump();
      await expectMoving();
      await player.pause();
      await mount();
      await expectStopped();
      await player.play();
      await mount();
      await expectMoving();
      player.isBuffering = true;
      await mount();
      await expectStopped();
      player.isBuffering = false;
      await mount();
      await expectMoving();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await expectStopped();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await expectMoving();
      await mount(enabled: false);
      await expectStopped();
    },
  );

  testWidgets(
    'long press doubles scrolling speed and release restores it without jumping',
    (tester) async {
      await portrait(tester);
      final player = FakeNativePlayer()..isPlaying = true;
      addTearDown(player.dispose);
      await tester.pumpWidget(
        app(nativePlayer: player, danmaku: const [entry]),
      );
      await tester.pump();
      final before = tester.getTopLeft(moving).dx;
      await tester.pump(const Duration(milliseconds: 16));
      final normalStep = before - tester.getTopLeft(moving).dx;
      final gesture = await tester.startGesture(const Offset(200, 350));
      await tester.pump(const Duration(milliseconds: 600));
      expect(player.rate, 2);
      player.currentPosition = const Duration(milliseconds: 20600);
      player.positions.add(player.currentPosition);
      await tester.pump();
      final boosted = tester.getTopLeft(moving).dx;
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        boosted - tester.getTopLeft(moving).dx,
        closeTo(normalStep * 2, .0001),
      );
      final beforeRelease = tester.getTopLeft(moving).dx;
      await gesture.up();
      await tester.pump();
      expect(player.rate, 1);
      expect(tester.getTopLeft(moving).dx, beforeRelease);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        beforeRelease - tester.getTopLeft(moving).dx,
        closeTo(normalStep, .0001),
      );
    },
  );

  testWidgets(
    'horizontal seeking suspends extrapolation until the gesture ends',
    (tester) async {
      await portrait(tester);
      final player = FakeNativePlayer()..isPlaying = true;
      addTearDown(player.dispose);
      await tester.pumpWidget(
        app(
          nativePlayer: player,
          danmaku: const [
            entry,
            PlayletComment(id: 'seek', text: '拖动目标', offsetMs: 50000),
          ],
        ),
      );
      await tester.pump();
      final gesture = await tester.startGesture(const Offset(100, 350));
      await gesture.moveBy(const Offset(30, 0));
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(
        tester
            .widget<PlayletDanmakuLayer>(find.byType(PlayletDanmakuLayer))
            .playing,
        isFalse,
      );
      final sought = find.byKey(const ValueKey('danmaku-seek'));
      expect(player.currentPosition, const Duration(seconds: 54));
      expect(sought, findsOneWidget);
      final duringSeek = tester.getTopLeft(sought);
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getTopLeft(sought), duringSeek);
      await gesture.up();
      await tester.pump();
      expect(
        tester
            .widget<PlayletDanmakuLayer>(find.byType(PlayletDanmakuLayer))
            .playing,
        isTrue,
      );
      final afterSeek = tester.getTopLeft(sought);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getTopLeft(sought).dx, lessThan(afterSeek.dx));
    },
  );

  testWidgets(
    'changing player resets interpolation even at the same native position',
    (tester) async {
      await portrait(tester);
      final first = FakeNativePlayer()..isPlaying = true;
      final next = FakeNativePlayer()..isPlaying = true;
      addTearDown(first.dispose);
      addTearDown(next.dispose);
      await tester.pumpWidget(app(nativePlayer: first, danmaku: const [entry]));
      await tester.pump();
      final initial = tester.getTopLeft(moving);
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getTopLeft(moving).dx, lessThan(initial.dx));
      await tester.pumpWidget(app(nativePlayer: next, danmaku: const [entry]));
      expect(tester.getTopLeft(moving), initial);
      first.positions.add(const Duration(seconds: 100));
      await tester.pump();
      expect(tester.getTopLeft(moving), initial);
    },
  );
}
