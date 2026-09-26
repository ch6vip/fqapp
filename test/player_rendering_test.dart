import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/player_panel_preferences.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/widgets/player/story_player_panel.dart';
import 'package:fqapp/widgets/player/story_seek_bar.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';

void main() {
  setUp(() {
    // 官方画面撑满的缺省值取决于方向（非竖屏时 = !default_video_size_aspect_fit
    // = true）。本套用例验的是 contain 铺排，所以显式把 SP 置成关闭。
    SharedPreferences.setMockInitialValues({'is_fill_screen': false});
    PlayerPanelPreferences.setDefaultMute(true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });

  tearDown(() {
    PlayerPanelPreferences.setDefaultMute(true);
    debugOnRebuildDirtyWidget = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  for (final panelOpen in [false, true]) {
    testWidgets(
      'position ticks update progress without rebuilding the page (panel: $panelOpen)',
      (tester) async {
        final player = await _mount(tester);
        if (panelOpen) {
          await tester.tap(find.byKey(const ValueKey('player-catalog-bar')));
          // 打开动画 200ms；面板开着时当前集的循环声波 Lottie 让 settle 永不
          // 结束，只能用固定 pump（对照文档 §26）。首段带时长的 pump 是动画
          // ticker 的首个 tick，elapsed 被起点捕获吃掉，必须再给足时长并补
          // 一帧，把 _animatePanel 收尾的 setState 也 flush 掉。
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 150));
          await tester.pump(const Duration(milliseconds: 150));
          await tester.pump();
        }
        final builds = _recordBuilds();
        for (var tick = 1; tick <= 10; tick++) {
          player.emitPosition(Duration(seconds: tick));
          await tester.pump(const Duration(milliseconds: 200));
        }
        debugOnRebuildDirtyWidget = null;
        debugPrint('rendering: progress panel=$panelOpen $builds');
        if (!panelOpen) {
          expect(
            tester.widget<StorySeekBar>(find.byType(StorySeekBar)).value,
            closeTo(10 / 120, .0001),
          );
        } else {
          expect(find.byKey(const ValueKey('story-panel')), findsOneWidget);
          // 官方无右上角关闭钮：点遮罩关（`AnimationBottomDialog:604`）。
          final panelTop = tester
              .getTopLeft(find.byKey(const ValueKey('story-panel')))
              .dy;
          await tester.tapAt(Offset(200, panelTop - 60));
          await tester.pumpAndSettle();
          expect(
            tester.widget<StorySeekBar>(find.byType(StorySeekBar)).value,
            closeTo(10 / 120, .0001),
          );
        }
        expect(builds['PlayerPage'] ?? 0, 0);
        expect(builds['VideoPlayerChrome'] ?? 0, 0);
        expect(builds['StoryPlayerPanel'] ?? 0, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'more settings preserve the paused page, position and clear screen',
    (tester) async {
      final originalStyle = PlayerStyleConfig.instance;
      PlayerStyleConfig.instance = const PlayerStyleConfig(
        useNewPlayerBottomStyle: true,
      );
      addTearDown(() => PlayerStyleConfig.instance = originalStyle);
      final player = await _mount(tester, shortSeries: true);
      player.emitPosition(const Duration(seconds: 35));
      await player.pause();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('player-rate-text')));
      await tester.pumpAndSettle();
      player.calls.clear();
      await tester.tap(find.byKey(const ValueKey('player-more-fill-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-more-mute-row')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome))
            .fillScreen,
        isTrue,
      );
      expect(await PlayerPanelPreferences.loadFillScreen(), isTrue);
      expect(PlayerPanelPreferences.defaultMute, isFalse);
      await tester.tap(find.byKey(const ValueKey('player-more-rate-1.75')));
      await tester.pumpAndSettle();
      expect(player.calls, ['volume:1.0', 'rate:1.75']);
      expect(player.isPlaying, isFalse);
      expect(player.position, const Duration(seconds: 35));
      expect(find.text('恢复'), findsOneWidget);
      expect(await PlayerPreferences.loadPlaybackRate(), 1.75);
      await tester.tap(find.byKey(const ValueKey('player-rate-text')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey('player-more-fill-row')),
            )
            .properties
            .toggled,
        isTrue,
      );
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey('player-more-mute-row')),
            )
            .properties
            .toggled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('panel follows the finger without rebuilding the player chrome', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('player-catalog-bar')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();
    final panel = find.byKey(const ValueKey('story-panel'));
    final before = tester.getRect(panel);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('story-panel-drag'))),
    );
    // Accept the gesture and unlock expansion before measuring steady dragging.
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    final builds = _recordBuilds();
    for (var frame = 0; frame < 10; frame++) {
      await gesture.moveBy(const Offset(0, -8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugOnRebuildDirtyWidget = null;
    debugPrint('rendering: panel drag $builds');
    final after = tester.getRect(panel);
    expect(after.top, lessThan(before.top - 70));
    expect(
      tester.getRect(find.byKey(const ValueKey('video-frame'))).bottom,
      lessThanOrEqualTo(after.top + 1),
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(builds['VideoPlayerChrome'] ?? 0, 0);
    expect(builds['StoryPlayerPanel'] ?? 0, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('continuous seeking only redraws the timeline and commits once', (
    tester,
  ) async {
    final player = await _mount(tester);
    final track = tester.getRect(find.byKey(const ValueKey('video-seek')));
    final gesture = await tester.startGesture(
      Offset(track.left + track.width * .2, track.center.dy),
    );
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump();
    final initial = tester
        .widget<StorySeekBar>(find.byType(StorySeekBar))
        .value;
    final builds = _recordBuilds();
    for (var frame = 0; frame < 10; frame++) {
      await gesture.moveBy(const Offset(4, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugOnRebuildDirtyWidget = null;
    debugPrint('rendering: seek drag $builds');
    final end = tester.widget<StorySeekBar>(find.byType(StorySeekBar)).value;
    expect(end, greaterThan(initial));
    expect(builds['VideoPlayerChrome'] ?? 0, 0);
    expect(builds['PlayerPage'] ?? 0, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      player.calls.where((call) => call.startsWith('seek:')),
      hasLength(1),
    );
    expect(player.position.inMilliseconds, closeTo(end * 120000, 1));
    expect(player.isPlaying, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late duration enables seeking using the latest position', (
    tester,
  ) async {
    final player = await _mount(tester, duration: Duration.zero);
    player.emitPosition(const Duration(seconds: 30));
    await tester.pump();
    expect(
      tester.widget<StorySeekBar>(find.byType(StorySeekBar)).enabled,
      false,
    );
    player.totalDuration = const Duration(minutes: 2);
    player.durations.add(player.totalDuration);
    await tester.pump();
    final seek = tester.widget<StorySeekBar>(find.byType(StorySeekBar));
    expect(seek.enabled, true);
    expect(seek.value, .25);
    final builds = _recordBuilds();
    for (var event = 0; event < 5; event++) {
      player.durations.add(player.totalDuration);
      player.playingEvents.add(player.isPlaying);
      await tester.pump();
    }
    debugOnRebuildDirtyWidget = null;
    expect(builds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(1080, 1920),
    const Size(1920, 1080),
    const Size(1080, 1080),
  ]) {
    testWidgets('panel animation retains the active texture for $size', (
      tester,
    ) async {
      final player = await _mount(tester, videoSize: size);
      final texture = find.byKey(const ValueKey('player-texture'));
      final element = tester.element(texture);
      final box = tester.renderObject<TextureBox>(texture);
      final originalRect = tester.getRect(texture);
      final calls = List<String>.of(player.calls);
      final rectangles = <Rect>{originalRect};

      Future<void> checkFrames() async {
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.element(texture), same(element));
          expect(tester.renderObject<TextureBox>(texture), same(box));
          expect(box.attached, true);
          expect(box.textureId, player.textureId);
          expect(box.freeze, false);
          expect(find.byKey(const ValueKey('player-cover')), findsNothing);
          final rect = tester.getRect(texture);
          rectangles.add(rect);
          expect(rect.width, greaterThan(0));
          expect(rect.height, greaterThan(0));
          expect(rect.width / rect.height, closeTo(size.aspectRatio, .001));
          expect(player.calls, calls);
          expect(player.playing, true);
          expect(tester.takeException(), isNull);
        }
      }

      // Include the frame that inserts/removes the panel, plus repeated cycles.
      for (var cycle = 0; cycle < 3; cycle++) {
        await tester.tap(find.byKey(const ValueKey('player-catalog-bar')));
        await checkFrames();
        expect(find.byKey(const ValueKey('story-panel')), findsOneWidget);
        // 官方无右上角关闭钮：点遮罩关（`AnimationBottomDialog:604`）。
        final panelTop = tester
            .getTopLeft(find.byKey(const ValueKey('story-panel')))
            .dy;
        await tester.tapAt(Offset(200, panelTop - 60));
        await checkFrames();
        expect(find.byKey(const ValueKey('story-panel')), findsNothing);
        expect(tester.getRect(texture), originalRect);
      }
      expect(rectangles.length, greaterThan(10));
    });
  }

  testWidgets(
    'texture rotation preserves portrait layout through panel animation',
    (tester) async {
      final player = _RotatedPlayer();
      await _mount(tester, player: player);
      final texture = find.byKey(const ValueKey('player-texture'));
      final box = tester.renderObject<TextureBox>(texture);
      final frame = find.byKey(const ValueKey('video-frame'));

      void checkRotation() {
        final rotation = tester.widget<RotatedBox>(
          find.ancestor(of: texture, matching: find.byType(RotatedBox)),
        );
        expect(rotation.quarterTurns, 1);
        // Media3 has already swapped display width/height. RotatedBox gives the
        // decoder texture landscape constraints and presents portrait output.
        expect(box.size.aspectRatio, closeTo(1920 / 1080, .001));
        expect(
          tester.getRect(frame).size.aspectRatio,
          closeTo(1080 / 1920, .001),
        );
      }

      checkRotation();
      await tester.tap(find.byKey(const ValueKey('player-catalog-bar')));
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.renderObject<TextureBox>(texture), same(box));
        checkRotation();
      }
      expect(tester.takeException(), isNull);
    },
  );
}

class _RotatedPlayer extends ControlledNativePlayer {
  @override
  int get videoRotationCorrection => 90;
}

Map<String, int> _recordBuilds() {
  final counts = <String, int>{};
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (element.widget is PlayerPage ||
        element.widget is VideoPlayerChrome ||
        element.widget is StoryPlayerPanel ||
        element.widget is StorySeekBar) {
      final name = element.widget.runtimeType.toString();
      counts.update(name, (count) => count + 1, ifAbsent: () => 1);
    }
  };
  return counts;
}

Future<ControlledNativePlayer> _mount(
  WidgetTester tester, {
  Duration duration = const Duration(minutes: 2),
  Size videoSize = const Size(1080, 1920),
  ControlledNativePlayer? player,
  bool shortSeries = false,
}) async {
  final activePlayer = (player ?? ControlledNativePlayer())
    ..width = videoSize.width.toInt()
    ..height = videoSize.height.toInt()
    ..totalDuration = duration;
  await tester.binding.setSurfaceSize(const Size(400, 800));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    debugOnRebuildDirtyWidget = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        shortSeries: shortSeries,
        bookId: 'rendering-book',
        title: '播放渲染测试',
        eps: [
          for (var index = 1; index <= 80; index++)
            Chapter(itemId: '$index', title: '第 $index 集', volumeName: ''),
        ],
        startIndex: 0,
        historyStore: ControlledReaderStore(),
        contentLoader: (chapter) async => {
          'video_url': 'https://example.invalid/${chapter.itemId}.mp4',
        },
        playerFactory: () => activePlayer,
        seriesLoader: (_) async => SeriesDetail.empty,
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
  return activePlayer;
}
