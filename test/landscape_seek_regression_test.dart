import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/player/story_seek_bar.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('landscape seek track follows position ticks while paused', (
    tester,
  ) async {
    final player = FakeNativePlayer();
    await _mount(tester, player);
    expect(_bar(tester).value, closeTo(20 / 120, .001));
    player.currentPosition = const Duration(seconds: 65);
    player.positions.add(player.currentPosition);
    await tester.pump();
    expect(_bar(tester).value, closeTo(65 / 120, .001));
  });

  for (final playing in [false, true]) {
    for (final portraitSource in [false, true]) {
      testWidgets('landscape drag keeps recognizer and playback usable '
          '(playing=$playing, portraitSource=$portraitSource)', (tester) async {
        final player = FakeNativePlayer(
          width: portraitSource ? 1080 : 1920,
          height: portraitSource ? 1920 : 1080,
        )..isPlaying = playing;
        await _mount(tester, player);
        final initialState = tester.state(
          find.byKey(const ValueKey('landscape-seek')),
        );
        final rect = tester.getRect(
          find.byKey(const ValueKey('landscape-seek')),
        );
        final initialValue = _bar(tester).value;
        final gesture = await tester.startGesture(
          Offset(rect.left + rect.width * initialValue, rect.center.dy),
        );
        await gesture.moveBy(const Offset(55, 0));
        await tester.pump();
        expect(
          tester.state(find.byKey(const ValueKey('landscape-seek'))),
          same(initialState),
        );
        expect(player.isPlaying, isFalse);
        expect(_bar(tester).seeking, isTrue);
        final firstValue = _bar(tester).value;
        await gesture.moveBy(const Offset(95, 0));
        await tester.pump();
        expect(_bar(tester).value, greaterThan(firstValue));
        expect(
          _bar(tester).value,
          closeTo(initialValue + 150 / rect.width, .005),
        );
        final target = _bar(tester).value;
        await gesture.up();
        await tester.pumpAndSettle();
        expect(_bar(tester).seeking, isFalse);
        expect(
          player.currentPosition.inMilliseconds / 120000,
          closeTo(target, .01),
        );
        expect(player.isPlaying, playing);
        await tester.tap(find.byKey(const ValueKey('landscape-play')));
        await tester.pumpAndSettle();
        expect(player.isPlaying, !playing);
        await tester.tap(find.byKey(const ValueKey('landscape-play')));
        await tester.pumpAndSettle();
        expect(player.isPlaying, playing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'cancelled landscape drag releases seek state and resumes playback',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      await _mount(tester, player);
      final rect = tester.getRect(find.byKey(const ValueKey('landscape-seek')));
      final gesture = await tester.startGesture(rect.center);
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(_bar(tester).seeking, isFalse);
      expect(player.isPlaying, isTrue);
      await tester.tap(find.byKey(const ValueKey('landscape-play')));
      await tester.pumpAndSettle();
      expect(player.isPlaying, isFalse);
    },
  );
}

StorySeekBar _bar(WidgetTester tester) =>
    tester.widget<StorySeekBar>(find.byKey(const ValueKey('landscape-seek')));

Future<void> _mount(WidgetTester tester, FakeNativePlayer player) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
    await tester.binding.setSurfaceSize(null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: StreamBuilder<bool>(
        stream: player.playingStream,
        initialData: player.playing,
        builder: (context, playing) => VideoPlayerChrome(
          player: player,
          title: '拖动回归',
          episodes: [
            Chapter(itemId: '1', title: '第1集', volumeName: ''),
            Chapter(itemId: '2', title: '第2集', volumeName: ''),
          ],
          currentIndex: 0,
          duration: player.duration,
          playing: playing.data!,
          shortSeries: true,
          openFullScreen: true,
          onSelectEpisode: (_) async {},
          onError: (error) => fail('$error'),
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
