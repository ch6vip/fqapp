import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/player_layout_preferences.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

/// 分屏视频盒在拿到解码尺寸之前就该定型；`auto` 档则要等片源取向确定。
///
/// 此前 `PlayerVideoLayout.sourceSize` 把 0×0 当成封面预览的 9:16：首次进入
/// 播放页先按竖版摆好盒子（407 宽 → 356.6dp），首帧到达后横版片源再收成
/// 228.9dp，整块画面跟着跳一次。
void main() {
  testWidgets('a split box is 16:9 before the decoder reports', (tester) async {
    await tester.binding.setSurfaceSize(const Size(407, 904));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = FakeNativePlayer(width: 0, height: 0);
    Widget app() => _app(player, PlayerLayoutMode.split);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // 407 宽的手机（insets 39/16）：盒子直接是 16:9，面板在它下面。
    final stage = find.byKey(const ValueKey('player-split-stage'));
    expect(stage, findsOneWidget);
    expect(tester.getSize(stage).height, closeTo(407 / (16 / 9), .5));

    // 解码尺寸到达（1920×1080）：盒子不再变高，只是画面填进去。
    player.width = 1920;
    player.height = 1080;
    await tester.pumpWidget(app());
    await tester.pump();
    expect(tester.getSize(stage).height, closeTo(407 / (16 / 9), .5));

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('auto splits only after a wide source reports', (tester) async {
    await tester.binding.setSurfaceSize(const Size(407, 904));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = FakeNativePlayer(width: 0, height: 0);
    Widget app() => _app(player, PlayerLayoutMode.auto);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // 尺寸未知且没有历史：按竖版兜底，先不分屏（换集才不会每集闪一次）。
    expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);

    // 解码尺寸到达（1920×1080）：盒子直接是 16:9。
    player.width = 1920;
    player.height = 1080;
    await tester.pumpWidget(app());
    await tester.pump();
    final stage = find.byKey(const ValueKey('player-split-stage'));
    expect(stage, findsOneWidget);
    expect(tester.getSize(stage).height, closeTo(407 / (16 / 9), .5));

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets(
    'a hand-off keeps the last judgement and then follows the new source',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(407, 904));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final first = FakeNativePlayer(width: 1920, height: 1080);
      final next = FakeNativePlayer(width: 0, height: 0);
      Widget app(FakeNativePlayer player) =>
          _app(player, PlayerLayoutMode.auto);
      await tester.pumpWidget(app(first));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-split-stage')), findsOneWidget);

      // 换集：新播放器先是 0×0，沿用上一集（横版）的判定，不许弹回整屏。
      await tester.pumpWidget(app(next));
      await tester.pump();
      expect(find.byKey(const ValueKey('player-split-stage')), findsOneWidget);

      // 新集其实是竖版：尺寸到达后才收回沉浸式。
      next.width = 1080;
      next.height = 1920;
      await tester.pumpWidget(app(next));
      await tester.pump();
      expect(find.byKey(const ValueKey('player-split-stage')), findsNothing);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(const SizedBox.shrink());
      await first.dispose();
      await next.dispose();
    },
  );

  testWidgets('a missing player lays the split box out as unknown', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(407, 904));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 换集窗口里 _player 为 null：盒子要按 16:9 占位，不能回退到 9:16 的竖版高度。
    await tester.pumpWidget(_app(null, PlayerLayoutMode.split));
    await tester.pumpAndSettle();
    final stage = find.byKey(const ValueKey('player-split-stage'));
    expect(stage, findsOneWidget);
    expect(tester.getSize(stage).height, closeTo(407 / (16 / 9), .5));
  });

  testWidgets('a landscape series keeps its split across a player hand-off', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(407, 904));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final first = FakeNativePlayer(width: 1920, height: 1080);
    final next = FakeNativePlayer(width: 0, height: 0);
    Widget app(FakeNativePlayer player) => _app(player, PlayerLayoutMode.auto);
    await tester.pumpWidget(app(first));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-split-stage')), findsOneWidget);

    // 换集时沿用上次判定：不许先收回整屏、等尺寸到了再分屏。
    await tester.pumpWidget(app(next));
    await tester.pump();
    expect(find.byKey(const ValueKey('player-split-stage')), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await first.dispose();
    await next.dispose();
  });
}

Widget _app(NativePlayer? player, PlayerLayoutMode mode) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(padding: const EdgeInsets.only(top: 39, bottom: 16)),
    child: child!,
  ),
  home: VideoPlayerChrome(
    player: player,
    episodes: [Chapter(itemId: '1', title: '第一集', volumeName: '')],
    currentIndex: 0,
    duration: player?.duration ?? Duration.zero,
    playing: true,
    shortSeries: true,
    layoutMode: mode,
    splitPanel: const ColoredBox(
      key: ValueKey('fake-split-panel'),
      color: Colors.blueGrey,
    ),
    onSelectEpisode: (index) async {},
    onError: (error) => throw error,
    child: const ColoredBox(color: Colors.black),
  ),
);
