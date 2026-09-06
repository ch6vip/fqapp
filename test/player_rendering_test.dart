import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/widgets/player/story_player_panel.dart';
import 'package:fqapp/widgets/player/story_seek_bar.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });

  tearDown(() {
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
          await tester.tap(find.byTooltip('选集'));
          await tester.pumpAndSettle();
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
          await tester.tap(find.byTooltip('关闭面板'));
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

  testWidgets('panel follows the finger without rebuilding the player chrome', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(find.byTooltip('选集'));
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
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
}) async {
  final player = ControlledNativePlayer()
    ..width = 1080
    ..height = 1920
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
        bookId: 'rendering-book',
        title: '播放渲染测试',
        description: '剧情简介',
        eps: [
          for (var index = 1; index <= 80; index++)
            Chapter(itemId: '$index', title: '第 $index 集', volumeName: ''),
        ],
        startIndex: 0,
        historyStore: ControlledReaderStore(),
        contentLoader: (chapter) async => {
          'video_url': 'https://example.invalid/${chapter.itemId}.mp4',
        },
        playerFactory: () => player,
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
  return player;
}
