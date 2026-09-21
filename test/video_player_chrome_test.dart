import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/widgets/player/story_seek_bar.dart';
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
    'launchCatalogPanel opens the episode catalog without a tap',
    (tester) async {
      // 官方「观看全集」= goToSingleFeed 的 setLaunchCatalogPanel(true)：
      // 进播放页即弹选集面板，不用再点一次「选集」。
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(_app(player, launchCatalogPanel: true));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('选集'), findsOneWidget);
      expect(find.byKey(const ValueKey('story-episode-0')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets(
    'double tap shows the heart, fires the like callback and never pauses',
    (tester) async {
      // 官方播放页双击 = 点赞（`lh3.a.onDoubleTap`），不再是暂停/继续。
      final player = FakeNativePlayer()..isPlaying = true;
      var likes = 0;
      await tester.pumpWidget(_app(player, onDoubleTapLike: () => likes++));
      await tester.pumpAndSettle();
      final surface = tester.getCenter(
        find.byKey(const ValueKey('video-surface')),
      );
      await tester.tapAt(surface);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(surface);
      await tester.pump();
      expect(likes, 1);
      expect(find.byKey(const ValueKey('player-heart-1')), findsOneWidget);
      expect(player.calls.where((call) => call == 'pause'), isEmpty);
      // 700ms 动效走完归零，双击可以再次重放心形。
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-heart-1')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets('a horizontal drag seeks the episode and consumes the hint', (
    tester,
  ) async {
    // 官方播放页手势层：横滑 = 调进度（映射整集时间轴，拖动中实时 seek）。
    final player = FakeNativePlayer()..isPlaying = true;
    var hintConsumed = 0;
    await tester.pumpWidget(
      _app(
        player,
        showSeekHint: true,
        onSeekHintConsumed: () => hintConsumed++,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('左右滑动可调整进度'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('video-surface')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();
    expect(player.calls.where((call) => call.startsWith('seek:')), isNotEmpty);
    expect(hintConsumed, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets(
    'the official bottom CTA bar appears with controls hidden and opens the catalog',
    (tester) async {
      // 官方 cjw.xml（d99 槽注入）：控制条隐藏的观看中出「观看完整短剧」
      // CTA 条，点击进选集面板（官方 schema 跳转的等价物）。
      final player = FakeNativePlayer()..isPlaying = true;
      final selected = <int>[];
      await tester.pumpWidget(_app(player, selected: selected));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-cta-bar')), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const ValueKey('player-cta-bar')), findsOneWidget);
      expect(find.text('观看完整短剧'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-cta-bar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('story-episode-0')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets(
    'episodeEndedWaiting shows the official bottom bar with the right copy',
    (tester) async {
      // 官方 `BottomContainer`（`cia.xml`）：有下一集是「上滑继续观看短剧」，
      // 最后一集是「已是最后一集」。
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(_app(player, episodeEndedWaiting: true));
      await tester.pumpAndSettle();
      expect(find.text('上滑继续观看短剧'), findsOneWidget);
      await tester.pumpWidget(
        _app(player, episodeEndedWaiting: true, currentIndex: 1),
      );
      await tester.pumpAndSettle();
      expect(find.text('已是最后一集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

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

  testWidgets('an older rate reply cannot overwrite a newer saved selection', (
    tester,
  ) async {
    final player = _RateAcknowledgementPlayer();
    final olderReply = Completer<void>();
    try {
      await tester.pumpWidget(_app(player));
      await tester.pumpAndSettle();
      player.rateAcknowledgement = olderReply;
      await tester.tap(find.byTooltip('倍速 1.5×'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '2×'));
      await tester.pumpAndSettle();
      player.rateAcknowledgement = null;
      await tester.tap(find.byTooltip('倍速 2×'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '1.25×'));
      await tester.pumpAndSettle();
      expect(await PlayerPreferences.loadPlaybackRate(), 1.25);
      olderReply.complete();
      await tester.pumpAndSettle();
      expect(await PlayerPreferences.loadPlaybackRate(), 1.25);
      expect(player.rate, 1.25);
    } finally {
      if (!olderReply.isCompleted) olderReply.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
  });

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

  testWidgets('replacing the player disconnects its old position updates', (
    tester,
  ) async {
    final first = FakeNativePlayer();
    final second = FakeNativePlayer()
      ..currentPosition = const Duration(seconds: 80);
    try {
      await tester.pumpWidget(_app(first));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_app(second));
      await tester.pumpAndSettle();
      first.positions.add(const Duration(seconds: 119));
      await tester.pump();
      expect(
        tester.widget<StorySeekBar>(find.byType(StorySeekBar)).value,
        closeTo(80 / 120, .0001),
      );
      await second.seek(const Duration(seconds: 90));
      await tester.pump();
      expect(tester.widget<StorySeekBar>(find.byType(StorySeekBar)).value, .75);
      expect(find.text('01:30 / 02:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      second.positions.add(const Duration(seconds: 100));
      await tester.pump();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await first.dispose();
      await second.dispose();
    }
  });
}

class _RateAcknowledgementPlayer extends FakeNativePlayer {
  Completer<void>? rateAcknowledgement;

  @override
  Future<void> setRate(double rate) async {
    final acknowledgement = rateAcknowledgement;
    await super.setRate(rate);
    await acknowledgement?.future;
  }
}

Widget _app(
  FakeNativePlayer player, {
  List<int>? selected,
  TextScaler textScaler = TextScaler.noScaling,
  bool launchCatalogPanel = false,
  VoidCallback? onDoubleTapLike,
  bool showSeekHint = false,
  VoidCallback? onSeekHintConsumed,
  bool episodeEndedWaiting = false,
  int currentIndex = 0,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: StreamBuilder<bool>(
    stream: player.playingStream,
    initialData: player.playing,
    builder: (context, playing) => VideoPlayerChrome(
      player: player,
      episodes: [
        Chapter(itemId: '1', title: '第一集', volumeName: ''),
        Chapter(itemId: '2', title: '第二集', volumeName: ''),
      ],
      currentIndex: currentIndex,
      duration: player.duration,
      playing: playing.data!,
      onSelectEpisode: (index) async {
        selected?.add(index);
      },
      onError: (error) => throw error,
      launchCatalogPanel: launchCatalogPanel,
      onDoubleTapLike: onDoubleTapLike,
      showSeekHint: showSeekHint,
      onSeekHintConsumed: onSeekHintConsumed,
      episodeEndedWaiting: episodeEndedWaiting,
      child: const ColoredBox(color: Colors.black),
    ),
  ),
);
