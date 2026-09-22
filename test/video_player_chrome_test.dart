import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
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
    await tester.tap(find.byTooltip('快进10秒'));
    await tester.pumpAndSettle();
    expect(player.calls, contains('seek:70'));
    player.currentPosition = const Duration(seconds: 116);
    player.positions.add(player.currentPosition);
    await tester.pump();
    await tester.tap(find.byTooltip('快进10秒'));
    await tester.pumpAndSettle();
    expect(player.calls.last, 'seek:120');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '2x'));
    await tester.pumpAndSettle();
    expect(player.rate, 2);
    expect(await PlayerPreferences.loadPlaybackRate(), 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets(
    'shortSeries portrait drops the transport row; tap toggles playback',
    (tester) async {
      // 官方播放页（`apf.xml`）竖屏没有上一集/±10/暂停/下一集运输条；
      // 暂停入口是单击画面（feed 卡同款）。横屏是官方底条（批次四），
      // 通用运输条两个朝向都不再出现。
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(_app(player, shortSeries: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('video-controls')), findsNothing);
      expect(find.byTooltip('快进10秒'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('video-surface')));
      await tester.pumpAndSettle();
      expect(player.calls.where((call) => call == 'pause'), isNotEmpty);
      await tester.tap(find.byKey(const ValueKey('video-surface')));
      // 不 settle：恢复播放后的 4s 自动隐藏会把控制条（含全屏 pill）收走。
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.calls.where((call) => call == 'play'), isNotEmpty);
      // 「观看全集」默认不弹选集面板（官方 AB `series_view_show_auto`
      // 默认 enabled=false 门住，更正 §22）；入口是底部目录条。
      expect(find.byKey(const ValueKey('story-episode-0')), findsNothing);
      // 全屏（测试窗口 800×600 → 横屏）后是官方底条：播放/下一集/倍速/
      // 选集 + 时间行与进度条，通用运输条不再出现（批次四）。
      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
      expect(find.byKey(const ValueKey('landscape-episodes')), findsOneWidget);
      expect(find.byTooltip('退出全屏'), findsNothing);
      expect(find.byTooltip('快进10秒'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets('shortSeries landscape shows the official bottom bar', (
    tester,
  ) async {
    // 官方横屏底条（`c0i` 控制行 + `cw7` 进度块）：播放/暂停 32dp、下一集
    // 32dp、倍速文本（1.5x）、选集；时间行「当前 / 总」居中 18sp；无
    // prev/±10/全屏钮（通用运输条残留，批次四删）。
    final player = FakeNativePlayer()..isPlaying = true;
    final selected = <int>[];
    await tester.pumpWidget(_app(player, shortSeries: true, selected: selected));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    expect(find.byKey(const ValueKey('video-controls')), findsNothing);
    expect(find.byTooltip('上一集'), findsNothing);
    expect(find.byTooltip('快退10秒'), findsNothing);
    expect(find.byTooltip('快进10秒'), findsNothing);
    expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('landscape-next')), findsOneWidget);
    expect(find.byKey(const ValueKey('landscape-rate')), findsOneWidget);
    expect(find.byKey(const ValueKey('landscape-episodes')), findsOneWidget);
    // setUp 的 mock 偏好是 1.5 → 官方倍速文案「1.5x」（`b2()`）。
    expect(find.text('1.5x'), findsOneWidget);
    // 时间行（官方横屏截图）：控制行内「当前 / 总」，恒 HH:MM:SS
    // （`d7.o(sec, true)`）；fake 初始 20 秒、时长 2 分钟。
    expect(find.byKey(const ValueKey('landscape-time')), findsOneWidget);
    expect(find.text('00:00:20'), findsOneWidget);
    expect(find.text('00:02:00'), findsOneWidget);
    expect(find.byKey(const ValueKey('landscape-seek')), findsOneWidget);
    // 功能行：追剧（图标+计数，无数据时「追剧」）；点赞无计数只出图标。
    expect(find.byKey(const ValueKey('landscape-follow')), findsOneWidget);
    expect(find.text('追剧'), findsOneWidget);
    expect(find.byKey(const ValueKey('landscape-like')), findsOneWidget);
    // 下一集 → 切到第二集（`a.java:963-976` 的 setCurrentItem 语义）。
    await tester.tap(find.byKey(const ValueKey('landscape-next')));
    await tester.pump();
    expect(selected, [1]);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('landscape episode panel is the official right drawer', (
    tester,
  ) async {
    // 官方横屏选集 = 右侧深色抽屉（✕头 + 4 列格子），非竖屏的底部
    // 白色面板（官方截图第二十三轮）。
    final player = FakeNativePlayer()..isPlaying = true;
    final selected = <int>[];
    await tester.pumpWidget(_app(player, shortSeries: true, selected: selected));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('landscape-episodes')));
    // 200ms 滑入；抽屉里有循环 Lottie，固定时长 pump（勿 settle）。
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('story-episode-drawer')), findsOneWidget);
    expect(find.byKey(const ValueKey('story-episode-0')), findsOneWidget);
    // 点格子 → 切集 + 关抽屉（220ms 退场后摘除）。
    await tester.tap(find.byKey(const ValueKey('story-episode-1')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(selected, [1]);
    expect(find.byKey(const ValueKey('story-episode-drawer')), findsNothing);
    // 重开 → ✕ 关闭。
    await tester.tap(find.byKey(const ValueKey('landscape-episodes')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('story-episode-drawer')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('story-drawer-close')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('story-episode-drawer')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('landscape next on the last episode toasts instead', (
    tester,
  ) async {
    // 最后一集点下一集：toast「当前已在最后一集」（`@string/dxx`），不切集。
    final player = FakeNativePlayer()..isPlaying = true;
    final selected = <int>[];
    await tester.pumpWidget(
      _app(player, shortSeries: true, selected: selected, currentIndex: 1),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('landscape-next')));
    await tester.pump();
    expect(find.text('当前已在最后一集'), findsOneWidget);
    expect(selected, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('landscape rate opens the official speed sheet', (tester) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(_app(player, shortSeries: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('landscape-rate')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-rate-row')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('shortSeries band persists after controls auto-hide', (
    tester,
  ) async {
    // 官方截图第二十二轮：控制条收起后，剧名/原著卡/贴底进度条/选集胶囊
    // 常驻；全屏 pill、右栏、倍速清屏行随控制条收走。
    final player = FakeNativePlayer()..isPlaying = true;
    var opened = 0;
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        seriesStatus: '已完结',
        originalBook: const RelatedWork(
          kind: 'book',
          id: '42',
          title: '从宿舍逃杀开始',
          label: '原著小说',
        ),
        onOpenOriginalBook: () => opened++,
      ),
    );
    await tester.pumpAndSettle();
    // 控制条可见：pill + 剧名，无原著卡；清屏走文字行，无图标钮。
    expect(find.byKey(const ValueKey('player-fullscreen-pill')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-original-book')), findsNothing);
    expect(find.byKey(const ValueKey('player-clear-icon')), findsNothing);
    // 3s 自动收起 → 常驻 band。
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('player-fullscreen-pill')), findsNothing);
    expect(find.byKey(const ValueKey('player-follow-button')), findsNothing);
    expect(find.byKey(const ValueKey('player-original-book')), findsOneWidget);
    expect(find.text('原著《从宿舍逃杀开始》'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-catalog-bar')), findsOneWidget);
    expect(find.text(' · 已完结 · 全2集'), findsOneWidget);
    // 胶囊右侧的清屏图标钮（用户指认）：band 态可见，控制条可见时没有
    // （那时清屏入口是倍速｜清屏文字行）。
    expect(find.byKey(const ValueKey('player-clear-icon')), findsOneWidget);
    // 原著卡点击 → 宿主跳原著详情。
    await tester.tap(find.byKey(const ValueKey('player-original-book')));
    expect(opened, 1);
    // 清屏图标钮 → 进清屏态：band 全收，只剩「恢复」出口。
    await tester.tap(find.byKey(const ValueKey('player-clear-icon')));
    await tester.pump();
    expect(find.byKey(const ValueKey('player-catalog-bar')), findsNothing);
    expect(find.byKey(const ValueKey('player-clear-icon')), findsNothing);
    expect(find.text('恢复'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('double tap toggles playback', (tester) async {
    // 双击点赞按用户决定不做了（无账号点赞数据，官方语义无从对齐）；
    // 恢复第十二轮之前的双击 = 播放/暂停。
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    final surface = tester.getCenter(
      find.byKey(const ValueKey('video-surface')),
    );
    await tester.tapAt(surface);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(surface);
    await tester.pumpAndSettle();
    expect(player.calls.where((call) => call == 'pause'), isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

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
      // 面板开着时当前集的循环声波 Lottie 永不定帧，用固定 pump 等开合动画。
      // 首段带时长的 pump 是 ticker 首个 tick（elapsed 被起点吃掉），要再给
      // 足时长把 200ms 动画推完，补一帧 flush 收尾 setState。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('story-episode-1')));
      await tester.pumpAndSettle();
      expect(selected, [1]);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets('short-series text row shows the official rate copy', (
    tester,
  ) async {
    // 官方右下角文字行（`SingleVideoHolder.java:1131-1171`）：倍速 1.0 显示
    // 「倍速」，其余 `数值x`（本用例档位 1.5 → 「1.5x」）；点它开更多面板，
    // 「清屏」点后切文案为「恢复」。通用播放器（详情页影视）不显示这一行。
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-rate-text')), findsNothing);
    await tester.pumpWidget(_app(player, shortSeries: true));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);
    expect(find.text('清屏'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-rate-row')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('an older rate reply cannot overwrite a newer saved selection', (
    tester,
  ) async {
    final player = _RateAcknowledgementPlayer();
    final olderReply = Completer<void>();
    try {
      await tester.pumpWidget(_app(player));
      await tester.pumpAndSettle();
      player.rateAcknowledgement = olderReply;
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '2x'));
      await tester.pumpAndSettle();
      player.rateAcknowledgement = null;
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '1.25x'));
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
      // 暂停态浮层的时间文字已按官方删除（§27），位置只反映在进度条上。
      expect(find.textContaining(' / '), findsNothing);
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
  bool shortSeries = false,
  bool showSeekHint = false,
  VoidCallback? onSeekHintConsumed,
  int currentIndex = 0,
  String? seriesStatus,
  RelatedWork? originalBook,
  VoidCallback? onOpenOriginalBook,
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
      shortSeries: shortSeries,
      showSeekHint: showSeekHint,
      onSeekHintConsumed: onSeekHintConsumed,
      seriesStatus: seriesStatus,
      originalBook: originalBook,
      onOpenOriginalBook: onOpenOriginalBook,
      child: const ColoredBox(color: Colors.black),
    ),
  ),
);
