import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/services/short_series_font_scale.dart';
import 'package:fqapp/widgets/player/story_seek_bar.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';
import 'support/controlled_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5});
    // 本文件的面板用例钉住深色分支（style=1）：药丸拖选/取消行/开关行是
    // 深色面板的交互；浅色分支（发布的默认）另有用例覆盖。
    PlayerStyleConfig.instance = const PlayerStyleConfig(
      useNewPlayerBottomStyle: true,
      morePanelStyle: 1,
    );
  });
  tearDown(() => PlayerStyleConfig.instance = PlayerStyleConfig.defaults);

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
      // 双击点赞已移除，但仍识别双击以吞掉其单击事件；单击要等
      // 手势识别窗口过去才确认，必须推进假时钟。
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.calls.where((call) => call == 'pause'), isNotEmpty);
      await tester.tap(find.byKey(const ValueKey('video-surface')));
      await tester.pump(const Duration(milliseconds: 400));
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

  for (final scenario in [
    (
      name: 'wide video',
      window: const Size(400, 888),
      scale: 1.0,
      vertical: false,
    ),
    (
      name: 'narrow screen with large text',
      window: const Size(280, 600),
      scale: 2.5,
      vertical: true,
    ),
  ]) {
    testWidgets('portrait controls remain separated for ${scenario.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(scenario.window);
      final player = FakeNativePlayer(
        width: scenario.vertical ? 1080 : 1920,
        height: scenario.vertical ? 1920 : 1080,
      )..isPlaying = true;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      var commentsOpened = 0;
      const title = '深夜噩梦：我有一双诡眼与很长的剧名';
      await tester.pumpWidget(
        _app(
          player,
          shortSeries: true,
          title: title,
          textScaler: TextScaler.linear(scenario.scale),
          padding: const EdgeInsets.fromLTRB(4, 32, 6, 24),
          onComments: () => commentsOpened++,
          hotComments: const [
            PlayletComment(id: 'hot', text: '太好了，是新剧，我们有救了，这是一条很长的评论'),
          ],
          originalBook: const RelatedWork(
            kind: 'book',
            id: '42',
            title: '恐怖噩梦：我有一双鬼眼',
            label: '原著小说',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      Rect rect(String key) => tester.getRect(find.byKey(ValueKey(key)));
      final pill = rect('player-fullscreen-pill');
      final comments = rect('player-comment-button');
      final titleRect = tester.getRect(find.text(title));
      final seek = rect('video-seek-layer');
      final catalog = rect('player-catalog-bar');
      final clear = rect('player-clear-screen');
      expect(pill.overlaps(comments), isFalse);
      expect(pill.bottom, lessThan(titleRect.top));
      expect(comments.bottom, lessThan(titleRect.top));
      expect(seek.overlaps(catalog), isFalse);
      expect(seek.overlaps(clear), isFalse);
      expect(catalog.overlaps(clear), isFalse);
      expect(clear.height, greaterThanOrEqualTo(48));
      if (!scenario.vertical) {
        final videoBottom = rect('video-frame').bottom;
        expect(pill.top - videoBottom, inInclusiveRange(12, 28));
      }
      await tester.tap(find.byKey(const ValueKey('player-comment-button')));
      expect(commentsOpened, 1);
      // 满屏布局容器的空白处仍属于视频手势，不能拦住单击暂停。
      await tester.tapAt(Offset(scenario.window.width / 2, 115));
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.calls, contains('pause'));
      await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
      await tester.pump();
      expect(find.text('恢复').hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey('player-comment-button')), findsNothing);
    });
  }

  testWidgets('shortSeries landscape shows the official bottom bar', (
    tester,
  ) async {
    // 官方横屏底条（`c0i` 控制行 + `cw7` 进度块）：播放/暂停 32dp、下一集
    // 32dp、倍速文本（1.5x）、选集；时间行「当前 / 总」居中 18sp；无
    // prev/±10/全屏钮（通用运输条残留，批次四删）。
    final player = FakeNativePlayer()..isPlaying = true;
    final selected = <int>[];
    await tester.pumpWidget(
      _app(player, shortSeries: true, selected: selected),
    );
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
    // 用户已移除追剧、点赞，横屏也不能残留入口。
    expect(find.byKey(const ValueKey('landscape-follow')), findsNothing);
    expect(find.text('追剧'), findsNothing);
    expect(find.byKey(const ValueKey('landscape-like')), findsNothing);
    // 下一集 → 切到第二集（`a.java:963-976` 的 setCurrentItem 语义）。
    await tester.tap(find.byKey(const ValueKey('landscape-next')));
    await tester.pump();
    expect(selected, [1]);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('旧底栏项序「清晰度 / 倍速」，多档流在场才显示清晰度', (tester) async {
    // bom.xml：`b2s`+`dqa`(清晰度) 在 `b2t`+`eby`(倍速) 之前；门同面板
    // `oi3/k.P()`（无多档不显示）。
    final player = FakeNativePlayer()..isPlaying = true;
    const variants = [
      EpisodeVariant(name: '1080P', url: 'u1080', keyHex: 'k', height: 1080),
      EpisodeVariant(name: '720P', url: 'u720', keyHex: 'k', height: 720),
    ];
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        newPlayerBottomStyle: false,
        qualityVariants: variants,
        currentQualityUrl: 'u720',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-quality-text')), findsOneWidget);
    expect(find.text('720P'), findsOneWidget);
    final quality = tester.getRect(
      find.byKey(const ValueKey('player-quality-text')),
    );
    final rate = tester.getRect(find.byKey(const ValueKey('player-rate-text')));
    expect(quality.right, lessThanOrEqualTo(rate.left));
    // 单流：整行不出现，不冒充官方恒显的分辨率名。
    await tester.pumpWidget(
      _app(player, shortSeries: true, newPlayerBottomStyle: false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-quality-text')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('横屏功能行清晰度入口亮当前档名', (tester) async {
    const variants = [
      EpisodeVariant(name: '1080P', url: 'u1080', keyHex: 'k', height: 1080),
      EpisodeVariant(name: '720P', url: 'u720', keyHex: 'k', height: 720),
    ];
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        qualityVariants: variants,
        currentQualityUrl: 'u720',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    expect(find.byKey(const ValueKey('landscape-quality')), findsOneWidget);
    expect(find.text('720P'), findsOneWidget);
    final quality = tester.getRect(
      find.byKey(const ValueKey('landscape-quality')),
    );
    final rate = tester.getRect(find.byKey(const ValueKey('landscape-rate')));
    expect(quality.right, lessThanOrEqualTo(rate.left));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('旧底栏进页自动清屏（o.W7），出口在面板行', (tester) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        newPlayerBottomStyle: false,
        onComments: () {},
        hotComments: const [PlayletComment(id: 'hot', text: '热评一条')],
      ),
    );
    await tester.pumpAndSettle();
    // W7 → T7(true)：清屏态压掉控制行与热评行。
    expect(find.byKey(const ValueKey('player-comment-button')), findsNothing);
    expect(find.text('热评'), findsNothing);
    // 面板行是官方给的全部出口（jm3.a 与底栏样式无关）：清屏后倍速文本
    // 仍在（showTextActions 的 _clearScreen 分支），打开见「退出清屏」。
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-clear-row')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-more-clear-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-comment-button')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('旧底栏 reverse 配置下不自动清屏', (tester) async {
    // FuncReverseOfClearScreen.reverse = true（O1() 为假）→ W7 第一道门挡下。
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        newPlayerBottomStyle: false,
        reverseClearScreen: true,
        onComments: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-comment-button')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('浅色更多面板（style 未下发）：药丸行在场，死行不出现', (tester) async {
    // 文件级 setUp 钉的是深色分支（style=1）；这里覆盖为发布配置的真实形态
    // （play_control_panel_style_v681 不下发 style）走浅色支。旧底栏 W7
    // 自动清屏给出倍速文字出口（同上面 W7 用例的链路）。
    PlayerStyleConfig.instance = const PlayerStyleConfig(
      useNewPlayerBottomStyle: true,
    );
    addTearDown(() => PlayerStyleConfig.instance = PlayerStyleConfig.defaults);
    final player = FakeNativePlayer()..isPlaying = true;
    final qualitySelections = <EpisodeVariant>[];
    const variants = [
      EpisodeVariant(name: '1080P', url: 'u1080', keyHex: 'k', height: 1080),
      EpisodeVariant(name: '720P', url: 'u720', keyHex: 'k', height: 720),
    ];
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        newPlayerBottomStyle: false,
        qualityVariants: variants,
        currentQualityUrl: 'u720',
        qualitySelections: qualitySelections,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-more-light-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-more-light-rate-row')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-more-light-quality-row')),
      findsOneWidget,
    );
    // 「720P」限定在面板内断言：旧底栏的清晰度文字入口同款文案在场。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-more-light-panel')),
        matching: find.text('720P'),
      ),
      findsOneWidget,
    );
    // 行集按官方布局对齐后按拍板裁剪（举报/投屏/不感兴趣移除）；取消/
    // 画面撑满/默认静音是深色 V2 布局的内容，浅色布局里没有。
    expect(find.text('取消'), findsNothing);
    expect(find.byKey(const ValueKey('player-more-fill-row')), findsNothing);
    expect(find.byKey(const ValueKey('player-more-mute-row')), findsNothing);
    expect(find.text('举报'), findsNothing);
    expect(find.text('投屏'), findsNothing);
    expect(find.text('不感兴趣'), findsNothing);
    expect(
      find.byKey(const ValueKey('player-more-light-download-row')),
      findsOneWidget,
    );
    // 听视频行要宿主接线（onOpenListenMode）才出现：feed 长按面板与测试
    // 助手都不接——整行隐藏，与官方未接行的可见性一致。
    expect(
      find.byKey(const ValueKey('player-more-light-listen-row')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('player-more-light-font-row')),
      findsOneWidget,
    );
    // 字体大小行尾注当前档名（官方 jk3/b.f()），chrome 恒接字号出口。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-more-light-panel')),
        matching: find.text('标准'),
      ),
      findsOneWidget,
    );
    // 清晰度药丸点击立即回传 EpisodeVariant（浅色支独有的回传通道）。
    await tester.tap(find.byKey(const ValueKey('player-more-light-quality-0')));
    await tester.pumpAndSettle();
    expect(qualitySelections.map((v) => v.url), ['u1080']);
    expect(
      find.byKey(const ValueKey('player-more-light-panel')),
      findsNothing,
    );
    // 倍速药丸走原速率持久化链路（与深色支同一条收尾）。
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-more-light-rate-1.25')));
    await tester.pumpAndSettle();
    expect(player.calls, contains('rate:1.25'));
    expect(await PlayerPreferences.loadPlaybackRate(), 1.25);
    expect(
      find.byKey(const ValueKey('player-more-light-panel')),
      findsNothing,
    );
    // 占位行只剩离线缓存：点击关面板并提示「暂未支持」，不留静默死入口。
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('player-more-light-download-row')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-more-light-panel')),
      findsNothing,
    );
    expect(find.text('离线缓存暂未支持'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('浅色面板字号档：级联弹层选档即生效并持久化', (tester) async {
    // 官方 jm3.t0：点击「字体大小」关面板并打开字号弹层（nm3.e），行尾
    // 档名（jk3/b.f()）随之刷新。档位系数 eh3/c：1.0/1.15/1.3。
    PlayerStyleConfig.instance = const PlayerStyleConfig(
      useNewPlayerBottomStyle: true,
    );
    addTearDown(() => PlayerStyleConfig.instance = PlayerStyleConfig.defaults);
    // 静态实例是进程级状态：进出都归零，别污染同文件后续用例。
    ShortSeriesFontScale.instance = 0;
    addTearDown(() => ShortSeriesFontScale.instance = 0);
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      _app(player, shortSeries: true, newPlayerBottomStyle: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-more-light-font-row')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-more-light-panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('player-font-scale-sheet')),
      findsOneWidget,
    );
    // 选「大号」：实例立即生效（save 同步写 instance），弹层不关——
    // 预览行要留在原地对比各档效果（官方样张语义）。
    await tester.tap(find.byKey(const ValueKey('player-font-scale-1')));
    await tester.pump();
    expect(ShortSeriesFontScale.instance, 1);
    expect(ShortSeriesFontScale.scale, 1.15);
    expect(
      find.byKey(const ValueKey('player-font-scale-sheet')),
      findsOneWidget,
    );
    // 点弹层外的 modal barrier 收掉弹层，重开面板看行尾档名。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-font-scale-sheet')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-more-light-panel')),
        matching: find.text('大号'),
      ),
      findsOneWidget,
    );
    // 持久化 SP（jk3/b 静态块），下次启动 load() 恢复。
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt('short_series_font_scale_manager/current_selected_index'),
      1,
    );
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
    await tester.pumpWidget(
      _app(player, shortSeries: true, selected: selected),
    );
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

  testWidgets('shortSeries catalog and information persist after auto-hide', (
    tester,
  ) async {
    // 本轮截图形态常驻「选集 + 清屏图标」，自动收起不切换入口。
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
    // 原著有数据就显示，不再等自动收起后才出现。
    expect(
      find.byKey(const ValueKey('player-fullscreen-pill')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('player-original-book')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-clear-icon')), findsOneWidget);
    final bookRect = tester.getRect(
      find.byKey(const ValueKey('player-original-book')),
    );
    final clearAction = find.byKey(const ValueKey('player-clear-screen'));
    final clearRect = tester.getRect(clearAction);
    final catalogRect = tester.getRect(
      find.byKey(const ValueKey('player-catalog-bar')),
    );
    // 3s 自动收起 → 常驻 band。
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('player-fullscreen-pill')), findsNothing);
    expect(find.byKey(const ValueKey('player-follow-button')), findsNothing);
    expect(find.byKey(const ValueKey('player-original-book')), findsOneWidget);
    expect(find.text('原著《从宿舍逃杀开始》'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-seek')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-catalog-bar')), findsOneWidget);
    expect(find.text(' · 已完结 · 全2集'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-clear-icon')), findsOneWidget);
    expect(clearAction.hitTestable(), findsOneWidget);
    expect(tester.getRect(clearAction), clearRect);
    expect(
      tester.getRect(find.byKey(const ValueKey('player-original-book'))),
      bookRect,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('player-catalog-bar'))),
      catalogRect,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('player-original-book'))).bottom,
      lessThanOrEqualTo(clearRect.top),
    );
    // 原著卡点击 → 宿主跳原著详情。
    await tester.tap(find.byKey(const ValueKey('player-original-book')));
    expect(opened, 1);
    await tester.tap(clearAction);
    await tester.pump();
    expect(find.byKey(const ValueKey('player-catalog-bar')), findsNothing);
    expect(find.byKey(const ValueKey('player-clear-icon')), findsNothing);
    expect(find.text('恢复'), findsOneWidget);
    expect(clearAction.hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets(
    'shortSeries portrait double tap has no like or playback action',
    (tester) async {
      // 用户移除了点赞；保留双击吞单击，避免一次双击被当成两次暂停。
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(_app(player, shortSeries: true));
      await tester.pumpAndSettle();
      final surface = tester.getCenter(
        find.byKey(const ValueKey('video-surface')),
      );
      await tester.tapAt(surface);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(surface);
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byKey(const ValueKey('player-like-animation')), findsNothing);
      expect(player.calls.where((call) => call == 'pause'), isEmpty);
      expect(player.calls.where((call) => call == 'play'), isEmpty);
      // 连续双击同样不出现动画或切换播放。
      await tester.tapAt(surface);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(surface);
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byKey(const ValueKey('player-like-animation')), findsNothing);
      expect(player.calls.where((call) => call == 'pause'), isEmpty);
      expect(player.calls.where((call) => call == 'play'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets('generic player keeps double tap as playback toggle', (
    tester,
  ) async {
    // 详情页的电影/电视剧走通用播放器（\`shortSeries: false\`），没有点赞
    // 链路，双击仍是播放/暂停。
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

  testWidgets(
    'landscape lock follows the official gate, position and release',
    (tester) async {
      // 官方 \`LandLockOptV705.enable_lock\`（默认 false）：配置关闭时锁按钮
      // 根本不存在；开启后按钮在横屏右缘，点击切换锁定并吞掉画面手势，
      // 每次触摸重新唤出按钮，退出全屏即解锁（\`EXIST_LAND_ACTIVITY\`）。
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(_app(player, shortSeries: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();

      final locked = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(
        _app(locked, shortSeries: true, landscapeLockEnabled: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      expect(find.byKey(const ValueKey('landscape-lock')), findsOneWidget);
      // 锁定时控件条与锁按钮一起保留；这里先锁定。
      await tester.tap(find.byKey(const ValueKey('landscape-lock')));
      await tester.pump();
      // 锁定后单击画面不暂停；可见锁会被收起。
      await tester.tap(find.byKey(const ValueKey('video-surface')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(locked.calls.where((call) => call == 'pause'), isEmpty);
      expect(find.byKey(const ValueKey('landscape-lock')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('landscape-lock')).hitTestable(),
        findsNothing,
      );
      // 透明锁的位置必须交给画面：第一次只唤出锁，不能直接解锁。
      await tester.tapAt(
        tester.getRect(find.byKey(const ValueKey('landscape-lock'))).center,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('landscape-play')), findsNothing);
      expect(
        find.byKey(const ValueKey('landscape-lock')).hitTestable(),
        findsOneWidget,
      );
      // 再点锁按钮解锁。
      await tester.tap(find.byKey(const ValueKey('landscape-lock')));
      await tester.pump();
      expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-surface')));
      // 横屏没有点赞链路，但 onDoubleTap 仍注册为播放切换，单击要等双击窗口。
      await tester.pump(const Duration(milliseconds: 400));
      // 官方横屏单击只切换控件条（`d.H6()`），不动播放状态；解锁后这条
      // 语义必须恢复，且不应把单击当成播放/暂停。
      expect(find.byKey(const ValueKey('landscape-play')), findsNothing);
      expect(locked.calls.where((call) => call == 'pause'), isEmpty);
      expect(locked.calls.where((call) => call == 'play'), isEmpty);
      // 控件条已收起，锁按钮随之消失；再唤出控件后重新锁定，验证退出横屏复位。
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('video-surface')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('landscape-lock')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('landscape-lock')));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await locked.dispose();
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

  testWidgets('short-series clear screen row keeps rate and restore actions', (
    tester,
  ) async {
    // 正常态按截图使用清屏图标，清屏后保留官方倍速文案与恢复出口。
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-rate-text')), findsNothing);
    await tester.pumpWidget(_app(player, shortSeries: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-rate-text')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    expect(find.text('1.5x'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-rate-row')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  for (final shortSeries in [false, true]) {
    testWidgets(
      'an older rate reply cannot overwrite a newer saved selection (short series: $shortSeries)',
      (tester) async {
        final player = _RateAcknowledgementPlayer();
        final olderReply = Completer<void>();
        try {
          await tester.pumpWidget(_app(player, shortSeries: shortSeries));
          await tester.pumpAndSettle();
          player.rateAcknowledgement = olderReply;
          await tester.tap(find.byTooltip('更多'));
          await tester.pumpAndSettle();
          await tester.tap(
            shortSeries
                ? find.byKey(const ValueKey('player-more-rate-2.0'))
                : find.widgetWithText(ChoiceChip, '2x'),
          );
          await tester.pumpAndSettle();
          player.rateAcknowledgement = null;
          await tester.tap(find.byTooltip('更多'));
          await tester.pumpAndSettle();
          await tester.tap(
            shortSeries
                ? find.byKey(const ValueKey('player-more-rate-1.25'))
                : find.widgetWithText(ChoiceChip, '1.25x'),
          );
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
      },
    );
  }

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
  EdgeInsets padding = EdgeInsets.zero,
  bool shortSeries = false,
  String title = '',
  VoidCallback? onComments,
  List<PlayletComment> hotComments = const [],
  bool showSeekHint = false,
  VoidCallback? onSeekHintConsumed,
  int currentIndex = 0,
  String? seriesStatus,
  RelatedWork? originalBook,
  VoidCallback? onOpenOriginalBook,
  bool newPlayerBottomStyle = true,
  bool hasBanner = false,
  bool padNewBottomStyle = false,
  bool reverseClearScreen = false,
  bool landscapeLockEnabled = false,
  List<EpisodeVariant> qualityVariants = const [],
  String? currentQualityUrl,
  List<EpisodeVariant>? qualitySelections,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: textScaler, padding: padding),
    child: child!,
  ),
  home: StreamBuilder<bool>(
    stream: player.playingStream,
    initialData: player.playing,
    builder: (context, playing) => VideoPlayerChrome(
      player: player,
      title: title,
      onComments: onComments,
      hotComments: hotComments,
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
      newPlayerBottomStyle: newPlayerBottomStyle,
      hasBanner: hasBanner,
      padNewBottomStyle: padNewBottomStyle,
      reverseClearScreen: reverseClearScreen,
      landscapeLockEnabled: landscapeLockEnabled,
      qualityVariants: qualityVariants,
      currentQualityUrl: currentQualityUrl,
      onQualitySelected: qualitySelections?.add,
      child: const ColoredBox(color: Colors.black),
    ),
  ),
);
