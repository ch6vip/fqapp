import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';
import 'support/controlled_player.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5}),
  );

  testWidgets('paused scrubbing stays paused, seek clamps and speed is saved', (
    tester,
  ) async {
    final player = FakeNativePlayer();
    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    expect(player.rate, 1.5);
    final track = tester.getRect(find.byKey(const ValueKey('video-seek')));
    await tester.tapAt(Offset(track.left + track.width * .8, track.center.dy));
    await tester.pump(const Duration(milliseconds: 350));
    expect(player.calls.where((call) => call.startsWith('seek:')), isEmpty);
    await tester.dragFrom(
      Offset(track.left + track.width * .1, track.center.dy),
      Offset(track.width / 3, 0),
    );
    await tester.pumpAndSettle();
    expect(player.calls, contains('seek:60'));
    expect(player.calls, isNot(contains('play')));
    await tester.tap(find.byTooltip('快进10秒'));
    await tester.pumpAndSettle();
    expect(player.calls, contains('seek:70'));
    player.currentPosition = const Duration(seconds: 116);
    player.positions.add(player.currentPosition);
    await tester.pump();
    await tester.tap(find.byTooltip('快进10秒'));
    await tester.pumpAndSettle();
    expect(player.calls.last, 'seek:120');
    await tester.tap(find.byTooltip('倍速 1.5×'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '2×'));
    await tester.pumpAndSettle();
    expect(player.rate, 2);
    expect(await PlayerPreferences.loadPlaybackRate(), 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets(
    'controls hide, long press restores speed, episode selection works',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      final selected = <int>[];
      await tester.pumpWidget(_app(player, selected: selected));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const ValueKey('video-controls')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('video-surface')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('video-controls')), findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('video-surface'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(player.rate, 2);
      expect(find.text('2× 加速中'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(player.rate, 1.5);
      await tester.tap(find.text('选集'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('story-episode-1')));
      await tester.pumpAndSettle();
      expect(selected, [1]);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets(
    'fullscreen back exits fullscreen and background playback pauses',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(_app(player));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全屏'));
      await tester.pump();
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byTooltip('全屏'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(player.isPlaying, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(player.isPlaying, true);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets('cancelling an accepted long press restores the saved speed', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    try {
      await tester.pumpWidget(_app(player));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('video-surface'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(player.rate, 2);
      await gesture.cancel();
      await tester.pump();
      expect(player.rate, 1.5);
      expect(find.text('2× 加速中'), findsNothing);
      expect(await PlayerPreferences.loadPlaybackRate(), 1.5);
      expect(player.isPlaying, true);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
  });

  testWidgets(
    'backgrounding during long press restores speed before resuming',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      try {
        await tester.pumpWidget(_app(player));
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('video-surface'))),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(player.rate, 2);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(player.rate, 1.5);
        expect(player.isPlaying, false);
        await gesture.cancel();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(player.isPlaying, true);
        expect(player.rate, 1.5);
        expect(await PlayerPreferences.loadPlaybackRate(), 1.5);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );

  testWidgets(
    'replacing the player during a long press restores both players to the saved rate',
    (tester) async {
      final first = FakeNativePlayer()..isPlaying = true;
      final second = FakeNativePlayer()..isPlaying = true;
      try {
        await tester.pumpWidget(_app(first));
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('video-surface'))),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(first.rate, 2);
        await tester.pumpWidget(_app(second));
        await tester.pump();
        expect(first.rate, 1.5);
        expect(second.rate, 1.5);
        await gesture.cancel();
        await tester.pump();
        expect(second.rate, 1.5);
        expect(find.text('2× 加速中'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await first.dispose();
        await second.dispose();
      }
    },
  );

  for (final playing in [true, false]) {
    for (final pendingSeek in [true, false]) {
      testWidgets(
        'seek then background preserves pause intent (playing: $playing, awaiting native: $pendingSeek)',
        (tester) async {
          final seek = Completer<void>();
          final player = ControlledNativePlayer(seekGate: seek)
            ..isPlaying = playing;
          await player.create('https://example.invalid/1.mp4', '');
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          try {
            await tester.pumpWidget(_app(player));
            await tester.pumpAndSettle();
            final track = tester.getRect(
              find.byKey(const ValueKey('video-seek')),
            );
            final gesture = await tester.startGesture(
              Offset(track.left + track.width * .2, track.center.dy),
            );
            await gesture.moveBy(const Offset(50, 0));
            await tester.pump();
            expect(player.isPlaying, false);
            if (pendingSeek) {
              await gesture.up();
              await tester.pump();
              expect(
                player.calls.where((call) => call.startsWith('seek:')),
                hasLength(1),
              );
            }
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            await tester.pump();
            if (!pendingSeek) await gesture.cancel();
            seek.complete();
            await tester.pump();
            expect(player.isPlaying, false);
            expect(player.calls.where((call) => call == 'play'), isEmpty);
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pump();
            expect(player.isPlaying, playing);
            expect(
              player.calls.where((call) => call == 'play'),
              hasLength(playing ? 1 : 0),
            );
            expect(tester.takeException(), isNull);
          } finally {
            if (!seek.isCompleted) seek.complete();
            await tester.pumpWidget(const SizedBox.shrink());
            await player.dispose();
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          }
        },
      );
    }
  }

  testWidgets('controls fit narrow screens with large fonts', (tester) async {
    await tester.binding.setSurfaceSize(const Size(280, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = FakeNativePlayer();
    await tester.pumpWidget(
      _app(player, textScaler: const TextScaler.linear(2)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('选集'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
}

Widget _app(
  FakeNativePlayer player, {
  List<int>? selected,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: StreamBuilder<bool>(
    stream: player.playingStream,
    initialData: player.playing,
    builder: (context, playing) => StreamBuilder<Duration>(
      stream: player.positionStream,
      initialData: player.position,
      builder: (context, position) => VideoPlayerChrome(
        player: player,
        episodes: [
          Chapter(itemId: '1', title: '第一集', volumeName: ''),
          Chapter(itemId: '2', title: '第二集', volumeName: ''),
        ],
        currentIndex: 0,
        position: position.data!,
        duration: player.duration,
        playing: playing.data!,
        onSelectEpisode: (index) async {
          selected?.add(index);
        },
        onError: (error) => throw error,
        child: const ColoredBox(color: Colors.black),
      ),
    ),
  ),
);
