import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/services/short_series_font_scale.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_settings.dart';
import 'package:fqapp/widgets/player/player_cover.dart';
import 'package:fqapp/widgets/player/story_seek_bar.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';
import 'support/controlled_player.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 横屏形态只看窗口宽高（设备横置即横屏，不再跟着 `_fullScreen` 走），
    // 而测试默认窗口 800×600 是横屏。这里的用例都按手机竖屏写，统一把视口
    // 钉成 400×888；要横屏的用例自己调 [_rotateToLandscape]。
    final view = binding.platformDispatcher.views.first;
    view.physicalSize = const Size(400, 888);
    view.devicePixelRatio = 1;
    SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5});
    // 本文件的面板用例钉住深色分支（style=1）：药丸拖选/取消行/开关行是
    // 深色面板的交互；浅色分支（发布的默认）另有用例覆盖。
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
    // 通用播放器没有底栏当前档：面板里留一行倍速入口，点开档位弹层。
    await tester.tap(find.byKey(const ValueKey('player-more-rate-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-rate-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-rate-sheet-4')));
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
      // 全屏后再把设备横过来（测试里手动转窗口）才是官方底条：播放/下一集/
      // 倍速/选集 + 时间行与进度条，通用运输条不再出现（批次四）。
      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      await _rotateToLandscape(tester);
      expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
      expect(find.byKey(const ValueKey('landscape-episodes')), findsOneWidget);
      expect(find.byTooltip('退出全屏'), findsNothing);
      expect(find.byTooltip('快进10秒'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets(
    'portrait fullscreen hides the chrome and a tap brings it back (#59)',
    (tester) async {
      // 设备没有转向时点「全屏观看」：`_fullScreen` 为真但视口仍是竖屏。
      // 修复前 `_scheduleHide` 对竖屏常驻形态一律早退，控件永远不收起，只有
      // 按钮文案变成「退出全屏」，画面一点没变（issue #59）。
      //
      final rotations = <List<Object?>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            rotations.add((call.arguments as List).cast<Object?>());
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.binding.setSurfaceSize(const Size(400, 888));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(_app(player, shortSeries: true));
      await tester.pumpAndSettle();

      // 浏览态：竖屏常驻，没有隐藏计时器（官方竖屏新底栏行为，保持不变）。
      expect(find.text('全屏观看'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('全屏观看'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      // 进全屏后整层控件（含「全屏观看」按钮与剧名/选集信息带）都收起。
      expect(find.text('全屏观看'), findsNothing);
      // 横版片源（本用例的默认尺寸 1920x1080）进全屏请求横屏。
      expect(rotations.last, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);

      // 单击画面把控件叫回来，而不是像浏览态那样切成暂停。竖屏全屏不是目录态。
      final paused = player.calls.where((call) => call == 'pause').length;
      await tester.tap(find.byKey(const ValueKey('video-surface')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('退出全屏'), findsOneWidget);
      expect(find.byKey(const ValueKey('player-catalog-bar')), findsNothing);
      expect(player.calls.where((call) => call == 'pause').length, paused);

      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets(
    'fullscreen follows the source shape, unknown stays landscape (#59)',
    (tester) async {
      // 竖版片源进全屏铺满竖屏；横版片源请求横屏；尺寸还没到时不发方向
      // 请求（未知尺寸无论按哪边兜底都会翻一下，issue #59）。
      final rotations = <List<Object?>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            rotations.add((call.arguments as List).cast<Object?>());
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const landscape = [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ];
      const portrait = ['DeviceOrientation.portraitUp'];

      for (final scenario in [
        (name: '竖版片源', size: const Size(1080, 1920), expected: portrait),
        (name: '尺寸还没到', size: Size.zero, expected: null),
        (name: '横版片源', size: const Size(1920, 1080), expected: landscape),
      ]) {
        final player = FakeNativePlayer()
          ..width = scenario.size.width.toInt()
          ..height = scenario.size.height.toInt();
        rotations.clear();
        await tester.pumpWidget(_app(player, shortSeries: true));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
        await tester.pump();
        await tester.pump();
        expect(
          rotations.isEmpty ? null : rotations.last,
          scenario.expected,
          reason: '${scenario.name} ${scenario.size}',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
      }
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
    await _rotateToLandscape(tester);
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
    await _rotateToLandscape(tester);
    expect(find.byKey(const ValueKey('landscape-quality')), findsOneWidget);
    expect(find.text('720P'), findsOneWidget);
    final quality = tester.getRect(
      find.byKey(const ValueKey('landscape-quality')),
    );
    final rate = tester.getRect(find.byKey(const ValueKey('landscape-rate')));
    final episodes = tester.getRect(
      find.byKey(const ValueKey('landscape-episodes')),
    );
    // B站横屏底条右簇的项序：选集 → 倍速 → 清晰度（清晰度压最右），
    // 与番茄官方「清晰度在倍速左侧」相反。
    expect(episodes.right, lessThanOrEqualTo(rate.left));
    expect(rate.right, lessThanOrEqualTo(quality.left));
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
    // 面板行是官方给的全部出口（jm3.a 与底栏样式无关）：清屏后底栏仍留
    // 「设置」出口（顶栏 ⋮ 被清屏压掉了），打开见「退出清屏」。
    await tester.tap(find.byKey(const ValueKey('player-settings-text')));
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

  testWidgets('浅色更多面板（style 未下发）：没有倍速/清晰度行，死行不出现', (tester) async {
    // 文件级 setUp 钉的是深色分支（style=1）；这里覆盖为发布配置的真实形态
    // （play_control_panel_style_v681 不下发 style）走浅色支。旧底栏 W7
    // 自动清屏给出底栏出口（同上面 W7 用例的链路）。
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
    await tester.tap(find.byKey(const ValueKey('player-settings-text')));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('player-more-light-panel'));
    expect(panel, findsOneWidget);
    // 倍速/清晰度不进视频设置：底栏右下角已经写着当前档。
    for (final key in [
      'player-more-light-rate-row',
      'player-more-light-quality-row',
    ]) {
      expect(
        find.descendant(of: panel, matching: find.byKey(ValueKey(key))),
        findsNothing,
        reason: '$key 不该出现在浅色面板里',
      );
    }
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
      find.descendant(of: panel, matching: find.text('标准')),
      findsOneWidget,
    );
    // 底栏的清晰度/倍速文字各自开自己的档位弹层——面板挡着时底栏不在场
    // （`showTextActions` 要 `unobstructed`），先收掉面板。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-quality-text')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-quality-sheet-0')));
    await tester.pumpAndSettle();
    expect(qualitySelections.map((v) => v.url), ['u1080']);
    // 底栏倍速文字走原速率持久化链路（与深色支同一条收尾）。
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-rate-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-rate-sheet-2')));
    await tester.pumpAndSettle();
    expect(player.calls, contains('rate:1.25'));
    expect(await PlayerPreferences.loadPlaybackRate(), 1.25);
    // 占位行只剩离线缓存：点击关面板并提示「暂未支持」，不留静默死入口。
    await tester.tap(find.byKey(const ValueKey('player-settings-text')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('player-more-light-download-row')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-light-panel')), findsNothing);
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
    await tester.tap(find.byKey(const ValueKey('player-settings-text')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-more-light-font-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-light-panel')), findsNothing);
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
    expect(find.byKey(const ValueKey('player-font-scale-sheet')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-settings-text')));
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

  testWidgets('浅色面板离线缓存行：宿主接线后真功能（点击回调），未接时占位', (tester) async {
    PlayerStyleConfig.instance = const PlayerStyleConfig(
      useNewPlayerBottomStyle: true,
    );
    addTearDown(() => PlayerStyleConfig.instance = PlayerStyleConfig.defaults);
    final player = FakeNativePlayer()..isPlaying = true;
    var opened = 0;
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        newPlayerBottomStyle: false,
        onOpenOfflineCache: () => opened++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-settings-text')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('player-more-light-download-row')),
    );
    await tester.pumpAndSettle();
    // 官方 jm3.u 语义：面板收起并打开下载弹窗（这里以回调记录代替）。
    expect(opened, 1);
    expect(find.byKey(const ValueKey('player-more-light-panel')), findsNothing);
    expect(find.text('离线缓存暂未支持'), findsNothing);
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
    await _rotateToLandscape(tester);
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
    await _rotateToLandscape(tester);
    await tester.tap(find.byKey(const ValueKey('landscape-next')));
    await tester.pump();
    expect(find.text('当前已在最后一集'), findsOneWidget);
    expect(selected, isEmpty);
    // 通知是画面偏下的紧凑胶囊，不是通栏 SnackBar；2 秒后自摘。
    expect(find.byType(SnackBar), findsNothing);
    final toast = tester.getRect(find.byKey(const ValueKey('player-toast')));
    expect(toast.width, lessThan(800 * .8));
    expect(toast.center.dx, closeTo(400, .5));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('当前已在最后一集'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('横屏弹幕设置同样是同宽的右侧面板', (tester) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      _app(player, shortSeries: true, onDanmakuSettingsChanged: (_) {}),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);
    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(
      find.byKey(const ValueKey('player-more-danmaku_settings-row')),
    );
    // 更多面板 200ms 退场后才级联打开设置面板（_pendingDanmakuSettings）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final panel = tester.getRect(
      find.byKey(const ValueKey('player-side-panel')),
    );
    expect(panel.width, closeTo(800 / 3, 1));
    expect(panel.right, closeTo(800, 1));
    expect(panel.height, 600);
    // 侧面板不画 sheet 手柄，设置项齐全（含新增的弹幕背景透明）。
    expect(
      find.byKey(const ValueKey('danmaku-settings-drag-handle')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('danmaku-settings-transparent')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('landscape rate opens its own picker instead of the settings', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(_app(player, shortSeries: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);
    await tester.tap(find.byKey(const ValueKey('landscape-rate')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // 底条上已经写着当前档，点它直接开档位面板，不再绕进视频设置。
    expect(find.byKey(const ValueKey('player-side-rates')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-more-panel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-side-rates-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(player.calls, contains('rate:1.25'));
    expect(find.byKey(const ValueKey('player-side-panel')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('shortSeries catalog and information stay resident', (
    tester,
  ) async {
    // 本轮截图形态常驻「选集 + 清屏图标」；官方竖屏新栏没有整层自动收起
    // （apf/cjc 链路取证，见 chrome._scheduleHide 注释），顶栏/药丸/信息区
    // 播放中也不消失。
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
    // 播放 4s 后控件仍全部在场：没有自动收起。
    await tester.pump(const Duration(seconds: 4));
    expect(
      find.byKey(const ValueKey('player-fullscreen-pill')),
      findsOneWidget,
    );
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
      await _rotateToLandscape(tester);
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();

      // 第二段重新从竖屏起：上面那台把窗口转成了横屏，这里复原。
      await tester.binding.setSurfaceSize(null);
      final locked = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(
        _app(locked, shortSeries: true, landscapeLockEnabled: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      await _rotateToLandscape(tester);
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
    // 底栏「倍速」开的是档位弹层，不再是视频设置。
    expect(find.byKey(const ValueKey('player-rate-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-rate-sheet-2')));
    await tester.pumpAndSettle();
    // 清屏态顶栏 ⋮ 被压掉，视频设置的出口是底栏「设置」。
    await tester.tap(find.byKey(const ValueKey('player-settings-text')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-panel')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  for (final shortSeries in [false, true]) {
    testWidgets(
      'an older rate reply cannot overwrite a newer saved selection (short series: $shortSeries)',
      (tester) async {
        final player = _RateAcknowledgementPlayer();
        final olderReply = Completer<void>();
        // 两支面板（通用兜底 / 短剧深色 V2）都在「视频设置」里留一行倍速
        // 入口（这套夹具的竖屏底栏不显示当前档），点开的是同一张档位弹层。
        // 档位索引对应 `PlayerPreferences.playbackRates`（0.75/1/1.25/1.5/2/3）。
        Future<void> pickRate(int index) async {
          await tester.tap(find.byTooltip('更多'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('player-more-rate-row')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('player-rate-sheet')),
            findsOneWidget,
            reason: 'pickRate($index) 没有开出档位弹层',
          );
          await tester.tap(find.byKey(ValueKey('player-rate-sheet-$index')));
          await tester.pumpAndSettle();
        }

        try {
          await tester.pumpWidget(_app(player, shortSeries: shortSeries));
          await tester.pumpAndSettle();
          player.rateAcknowledgement = olderReply;
          // 2x：原生回执被按住，落库先行的效果要等旧回执不能让位。
          await pickRate(4);
          player.rateAcknowledgement = null;
          // 紧接着改 1.25x：旧回执后到也不能把新档位覆盖回去。
          await pickRate(2);
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

  // P1-15：inactive（通知栏/控制中心）继续播，hidden 暂停，resumed 恢复。
  testWidgets('inactive keeps playing, hidden pauses, resume restores', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(player.isPlaying, true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(player.isPlaying, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(player.isPlaying, true);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

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

  testWidgets('横屏底条：时间行在通栏进度条之上，控制行在下', (tester) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(_app(player, shortSeries: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);

    final time = tester.getRect(find.byKey(const ValueKey('landscape-time')));
    final total = tester.getRect(
      find.byKey(const ValueKey('landscape-total-time')),
    );
    final seek = tester.getRect(find.byKey(const ValueKey('landscape-seek')));
    final play = tester.getRect(find.byKey(const ValueKey('landscape-play')));
    // B站 自上而下的顺序：时间行 → 进度条 → 控制行。
    expect(time.bottom, lessThanOrEqualTo(seek.top));
    expect(total.center.dy, closeTo(time.center.dy, 1));
    expect(seek.bottom, lessThanOrEqualTo(play.top));
    // 进度条通栏：左右各留 16dp，不再被时间/总时长挤窄。
    expect(seek.left, closeTo(16, 1));
    expect(seek.width, closeTo(800 - 32, 1));
    // 没有弹幕回调就不摆弹幕入口（与更多面板同一道门）。
    expect(find.byKey(const ValueKey('landscape-danmaku')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('横屏顶栏：两行标题 + 更多入口，锁贴右缘垂直中点', (tester) async {
    var comments = 0;
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        title: '深夜噩梦',
        seriesStatus: '已完结',
        onComments: () => comments++,
        landscapeLockEnabled: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);

    expect(find.text('深夜噩梦｜第1集'), findsOneWidget);
    expect(find.text('全2集 · 已完结'), findsOneWidget);
    // 横屏顶栏只剩 返回 / 标题 / 更多：评论入口已移除（竖屏右栏仍在）。
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('landscape-comment-button')),
      findsNothing,
    );
    expect(comments, 0);
    // 锁改到右缘垂直中点（B站横屏同位置），不再吊在顶栏下面。
    final lock = tester.getRect(find.byKey(const ValueKey('landscape-lock')));
    expect(lock.center.dy, closeTo(300, 1));
    expect(lock.right, greaterThan(800 - 64));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('横屏上下滑调亮度/音量并出 HUD', (tester) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('fqapp/native_player');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'gestureLevels') {
        return <String, double>{'brightness': .5, 'volume': .5};
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(_app(player, shortSeries: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);
    // 进横屏时预读档位；读完之后再开始手势。
    await tester.pump();
    calls.clear();
    final surface = tester.getRect(find.byKey(const ValueKey('video-surface')));

    // 左半区上滑：亮度升高。第一次 move 只够越过触摸 slop。
    var gesture = await tester.startGesture(
      surface.topLeft + Offset(surface.width * .25, surface.height * .6),
    );
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-gesture-label')))
          .data,
      '亮度',
    );
    await gesture.up();
    await tester.pump();
    final brightness = calls.lastWhere(
      (call) => call.method == 'setScreenBrightness',
    );
    expect((brightness.arguments as Map)['value'], greaterThan(.5));

    // 右半区下滑：音量降低，HUD 换成音量。
    gesture = await tester.startGesture(
      surface.topLeft + Offset(surface.width * .75, surface.height * .4),
    );
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-gesture-label')))
          .data,
      '音量',
    );
    await gesture.up();
    await tester.pump();
    final volume = calls.lastWhere((call) => call.method == 'setMediaVolume');
    expect((volume.arguments as Map)['value'], lessThan(.5));
    await tester.pumpWidget(const SizedBox.shrink());
    // 让双击识别器的 40ms 倒计时与 HUD 计时器在测试结束前走完。
    await tester.pump(const Duration(milliseconds: 400));
    await player.dispose();
  });

  testWidgets('横屏弹幕开关/设置收进更多面板，面板与选集抽屉同宽', (tester) async {
    var toggles = 0;
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        onToggleDanmaku: () => toggles++,
        onDanmakuSettingsChanged: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);
    // 底条左下的弹幕开关/设置已删，统一走右上角 ⋮。
    expect(find.byKey(const ValueKey('landscape-danmaku')), findsNothing);
    expect(
      find.byKey(const ValueKey('landscape-danmaku-settings')),
      findsNothing,
    );

    await tester.tap(find.byTooltip('更多'));
    // 先起一帧让路由动画开始，再走满 200ms 滑入（否则量到的是入场位移）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // 横屏不再用底部通栏 sheet：右侧面板，宽约 1/3 屏（800/3 ≈ 267）。
    final panel = tester.getRect(
      find.byKey(const ValueKey('player-side-panel')),
    );
    expect(panel.width, closeTo(800 / 3, 1));
    expect(panel.right, closeTo(800, 1));
    expect(panel.height, 600);
    // 面板里既有弹幕开关也有弹幕设置行（浅色支同样补齐了设置入口）。
    expect(find.byKey(const ValueKey('player-more-panel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-more-danmaku-row')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-more-danmaku_settings-row')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('player-more-danmaku-switch')));
    await tester.pump();
    expect(toggles, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('横屏矮窗（794×361）：视频设置只留宫格，底条直连档位面板', (tester) async {
    // 真机横屏只有约 361dp 高、面板 1/3 宽：倍速/清晰度已经写在底条右下角，
    // 视频设置里不再重复；剩下九项压成三列宫格才一屏放得下，面板里也不能
    // 有任何 RenderFlex 溢出（溢出会画黄黑条纹）。
    final player = FakeNativePlayer()..isPlaying = true;
    final selections = <EpisodeVariant>[];
    const variants = [
      EpisodeVariant(name: '1080P', url: 'u1080', keyHex: 'k', height: 1080),
      EpisodeVariant(name: '720P', url: 'u720', keyHex: 'k', height: 720),
      EpisodeVariant(name: '480P', url: 'u480', keyHex: 'k', height: 480),
    ];
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        qualityVariants: variants,
        currentQualityUrl: 'u720',
        qualitySelections: selections,
        onToggleDanmaku: () {},
        onDanmakuSettingsChanged: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(794, 361));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();

    Future<void> openMore() async {
      await tester.tap(find.byTooltip('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    await openMore();
    final panel = tester.getRect(
      find.byKey(const ValueKey('player-side-panel')),
    );
    expect(panel.width, closeTo(794 / 3, 1));
    expect(panel.right, closeTo(794, 1));
    // 倍速/清晰度已经在底条右下角显示当前档，视频设置里不再重复出现。
    expect(find.byKey(const ValueKey('player-more-rate')), findsNothing);
    expect(find.byKey(const ValueKey('player-more-quality')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-more-panel')),
        matching: find.text('倍速'),
      ),
      findsNothing,
    );
    // 宫格：开关与「点了就执行」的入口，一屏放得下，不用滚动找弹幕/字号。
    for (final tile in ['player-more-danmaku', 'player-more-download']) {
      expect(
        find.byKey(ValueKey(tile)),
        findsOneWidget,
        reason: '$tile 必须在宫格里',
      );
    }
    expect(
      find.byKey(const ValueKey('player-more-danmaku_settings')),
      findsOneWidget,
    );
    final font = tester.getRect(find.byKey(const ValueKey('player-more-font')));
    expect(font.bottom, lessThanOrEqualTo(panel.bottom));
    expect(tester.takeException(), isNull);

    // 弹幕设置：✕ 退回视频设置（而不是一路掉回画面），矮窗下不漏黄条。
    await tester.tap(
      find.byKey(const ValueKey('player-more-danmaku_settings')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('danmaku-settings-panel')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    // 「恢复默认」的提示（toast）在矮窗里也不能把页面撑溢出：提示条是
    // Overlay 上的浮层，溢出会在它上下画出黄黑条纹。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('danmaku-settings-reset')),
      60,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('danmaku-settings-panel')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('danmaku-settings-reset')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('设置成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('player-side-panel-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey('player-more-panel')), findsOneWidget);

    ShortSeriesFontScale.instance = 0;
    addTearDown(() => ShortSeriesFontScale.instance = 0);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-more-font-value')))
          .data,
      '标准',
    );
    await tester.tap(find.byKey(const ValueKey('player-more-font')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('player-font-scale-panel')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('player-font-scale-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('player-side-panel-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey('player-more-panel')), findsOneWidget);
    // 行尾跟着选档刷新（旧实现这里仍是打开面板时的「标准」快照）。
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-more-font-value')))
          .data,
      '大号',
    );
    await tester.tap(find.byKey(const ValueKey('player-side-panel-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // 底条倍速：点它直接开档位面板（六档全在列表里，不靠横滑）。
    await tester.tap(find.byKey(const ValueKey('landscape-rate')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('player-more-panel')), findsNothing);
    expect(find.byKey(const ValueKey('player-side-rates')), findsOneWidget);
    for (final label in ['0.75x', '1x', '1.25x', '1.5x', '2x', '3x']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-side-rates')),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: '$label 档必须在档位面板里可见',
      );
    }
    expect(tester.takeException(), isNull);
    // 选中即收起并生效。
    await tester.tap(find.byKey(const ValueKey('player-side-rates-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(player.calls, contains('rate:1.25'));
    expect(find.byKey(const ValueKey('player-side-panel')), findsNothing);

    // 底条清晰度：同样是自己的档位面板，选中回传 EpisodeVariant。
    await tester.tap(find.byKey(const ValueKey('landscape-quality')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('player-side-quality')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-side-quality')),
        matching: find.text('720P'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('player-side-quality-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(selections.map((variant) => variant.url), ['u1080']);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('横屏矮窗 + 大字号：顶栏底栏不溢出（黄黑条纹）', (tester) async {
    // 横屏只有约 361dp 高，顶栏 / 底条都是固定高度的浮层；字号放大 1.3 倍
    // 后行高跟着长，Column 一溢出就会在屏幕上下画出两条黄黑警示条。
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        textScaler: const TextScaler.linear(1.3),
        onToggleDanmaku: () {},
        onDanmakuSettingsChanged: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(794, 361));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('player-more-panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('横屏挖孔：画面整窗居中，设置面板与选集抽屉贴同一右缘', (tester) async {
    // 横握时摄像头只在左缘（padding.left）：画面必须按整窗居中（左右黑边
    // 等宽），三套右侧浮层必须贴同一右缘、同宽同高——外圈让安全区会把
    // 设置面板从屏幕边推开一截，和选集抽屉错位。
    final player = FakeNativePlayer(width: 1080, height: 1920)
      ..isPlaying = true;
    await tester.pumpWidget(
      _app(
        player,
        shortSeries: true,
        padding: const EdgeInsets.only(left: 44),
        onToggleDanmaku: () {},
        onDanmakuSettingsChanged: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);

    final frame = tester.getRect(find.byKey(const ValueKey('video-frame')));
    expect(frame.center.dx, closeTo(400, .5));
    expect(frame.left, closeTo(800 - frame.right, .5), reason: '左右黑边必须等宽');

    await tester.tap(find.byKey(const ValueKey('landscape-episodes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final drawer = tester.getRect(
      find.byKey(const ValueKey('story-episode-drawer')),
    );
    expect(drawer.right, closeTo(800, .5));
    // 抽屉同样不能让左侧安全区：否则标题与格子整体右偏。
    expect(
      tester.getCenter(find.byKey(const ValueKey('story-drawer-close'))).dx,
      closeTo(drawer.left + 24, 1),
    );
    expect(
      tester
          .getCenter(
            find.descendant(
              of: find.byKey(const ValueKey('story-episode-drawer')),
              matching: find.text('选集'),
            ),
          )
          .dx,
      closeTo(drawer.center.dx, 1),
    );
    await tester.tap(find.byKey(const ValueKey('story-drawer-close')));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final panel = tester.getRect(
      find.byKey(const ValueKey('player-side-panel')),
    );
    expect(panel.left, closeTo(drawer.left, .5));
    expect(panel.right, closeTo(drawer.right, .5));
    expect(panel.top, closeTo(drawer.top, .5));
    expect(panel.bottom, closeTo(drawer.bottom, .5));
    // 标题行与选集抽屉同为 64dp：并排切换面板时标题/✕ 不跳。
    expect(find.text('视频设置'), findsOneWidget);
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('player-side-panel-close')))
          .dy,
      closeTo(32, 1),
    );
    // 面板贴右缘：左边那条 44dp 安全区属于屏幕另一侧，面板内容不能让，
    // 否则 ✕ 与标题整体右偏、标题不在面板中线上。
    final close = tester.getRect(
      find.byKey(const ValueKey('player-side-panel-close')),
    );
    expect(close.center.dx, closeTo(panel.left + 24, 1));
    expect(tester.getCenter(find.text('视频设置')).dx, closeTo(panel.center.dx, 1));
    // 宫格块：三列均分面板宽，图标与文案都落在块中线；第一列贴着 12dp
    // 内边距起排，不再有「有的行有图标、有的行没有」的错位。
    final first = tester.getRect(
      find.byKey(const ValueKey('player-more-danmaku')),
    );
    final second = tester.getRect(
      find.byKey(const ValueKey('player-more-download')),
    );
    final tileWidth = (panel.width - 12 * 2 - 8 * 2) / 3;
    expect(first.left, closeTo(panel.left + 12, .5));
    expect(first.width, closeTo(tileWidth, .5));
    expect(second.width, closeTo(tileWidth, .5));
    expect(tester.getCenter(find.text('弹幕')).dx, closeTo(first.center.dx, 1));
    // 底条倍速：直接开档位面板，与抽屉/视频设置贴同一右缘。
    await tester.tap(find.byKey(const ValueKey('player-side-panel-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('landscape-rate')));
    await tester.pump();
    // 档位面板是独立路由，要等 200ms 滑入走完再量。
    await tester.pump(const Duration(milliseconds: 250));
    final rates = tester.getRect(
      find.byKey(const ValueKey('player-side-rates')),
    );
    expect(rates.left, closeTo(drawer.left, .5));
    expect(rates.right, closeTo(drawer.right, .5));
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('player-side-panel-close')))
          .dx,
      closeTo(rates.left + 24, 1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('大字号 + 极扁窗口：挤不下就不摆卡，够 48dp 才贴顶栏下沿', (tester) async {
    // 2 倍字号下顶栏行高约 73.6dp，底条固定 150dp：
    //   268 高 → 中间带 44.4dp，连 48dp 的卡都放不下 → 整卡不画；
    //   272 高 → 48.4dp，卡片贴顶栏下沿、且不压底条。
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FakeNativePlayer? active;

    Future<void> mountAt(Size window) async {
      if (active != null) {
        await tester.pumpWidget(const SizedBox.shrink());
        await active!.dispose();
      }
      tester.view.physicalSize = const Size(400, 888);
      final player = FakeNativePlayer(width: 1080, height: 1920)
        ..isPlaying = true;
      active = player;
      await tester.pumpWidget(
        _app(player, shortSeries: true, textScaler: TextScaler.linear(2)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      tester.view.physicalSize = window;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    addTearDown(() async {
      final player = active;
      if (player == null) return;
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });

    await mountAt(const Size(794, 268));
    expect(find.byKey(const ValueKey('landscape-next-card')), findsNothing);

    await mountAt(const Size(794, 272));
    final topBar = tester.getRect(find.byKey(const ValueKey('player-top-bar')));
    expect(topBar.height, greaterThan(56), reason: '大字号下顶栏应长高');
    final card = tester.getRect(
      find.byKey(const ValueKey('landscape-next-card')),
    );
    expect(card.top, greaterThanOrEqualTo(topBar.bottom - .01));
    expect(card.height, greaterThanOrEqualTo(48));
    expect(card.bottom, lessThanOrEqualTo(272 - 150 + .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('竖版片源横屏时，右黑边贴一张下一集卡', (tester) async {
    final selected = <int>[];
    final player = FakeNativePlayer(width: 1080, height: 1920)
      ..isPlaying = true;
    await tester.pumpWidget(
      _app(player, shortSeries: true, selected: selected),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);

    final frame = tester.getRect(find.byKey(const ValueKey('video-frame')));
    final card = tester.getRect(
      find.byKey(const ValueKey('landscape-next-card')),
    );
    // 卡片只占右侧黑边，不压画面；右半已溢出屏幕，只留左半截可见。
    expect(card.left, greaterThanOrEqualTo(frame.right));
    expect(card.right, greaterThan(800));
    // 卡片中心点在屏幕外，点露出的那半截。
    await tester.tapAt(Offset(card.left + 12, card.center.dy));
    await tester.pump();
    expect(selected, [1]);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('横版片源把下一集卡做成横幅叠在画面右缘，最后一集不摆', (tester) async {
    // 横版片源在横屏里铺满整宽，没有黑边可放：卡片改为叠在画面右缘内侧，
    // 否则太宽的视频整张卡都会消失（用户反馈的「部分视频不显示」）。
    await tester.binding.setSurfaceSize(const Size(400, 888));
    final wide = FakeNativePlayer(width: 1920, height: 1080)..isPlaying = true;
    await tester.pumpWidget(_app(wide, shortSeries: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);
    final frame = tester.getRect(find.byKey(const ValueKey('video-frame')));
    final card = tester.getRect(
      find.byKey(const ValueKey('landscape-next-card')),
    );
    // 横版片源铺满整宽：卡片叠进画面，且只留左半在屏内（右半溢出）。
    expect(card.left, lessThan(frame.right));
    expect(card.left, closeTo(800 - card.width / 2, .01));
    expect(card.right, closeTo(800 + card.width / 2, .01));
    // 卡片是 16:9 的横框（封面是竖版剧照，cover 后只露约 1/3）。
    expect(card.height, lessThanOrEqualTo(72));
    expect(card.width / card.height, closeTo(16 / 9, .05));
    await tester.pumpWidget(const SizedBox.shrink());
    await wide.dispose();

    // 最后一集没有下一集：不摆卡。
    await tester.binding.setSurfaceSize(const Size(400, 888));
    final last = FakeNativePlayer(width: 1080, height: 1920)..isPlaying = true;
    await tester.pumpWidget(_app(last, shortSeries: true, currentIndex: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await _rotateToLandscape(tester);
    expect(find.byKey(const ValueKey('landscape-next-card')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await last.dispose();
  });

  testWidgets('下一集卡排在锁定按钮正下方（真机横屏尺寸）', (tester) async {
    // 真机 794×361：锁在右缘中点不动，卡片贴在它下面、底边让开计时间行。
    tester.view.physicalSize = const Size(400, 888);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = FakeNativePlayer(width: 1080, height: 1920)
      ..isPlaying = true;
    await tester.pumpWidget(
      _app(player, shortSeries: true, landscapeLockEnabled: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    tester.view.physicalSize = const Size(794, 361);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final lock = tester.getRect(find.byKey(const ValueKey('landscape-lock')));
    final card = tester.getRect(
      find.byKey(const ValueKey('landscape-next-card')),
    );
    // 锁的位置保持右缘中点，卡片整块落在它下方。
    expect(lock.top, closeTo((361 - 48) / 2, .01));
    expect(card.top, greaterThanOrEqualTo(lock.bottom));
    // 不压底条的进度条（进度条上沿 y = 361 - 78 = 283），只在计时间行右侧
    // 的空白区里延展。
    expect(card.bottom, lessThanOrEqualTo(283));
    // 高度按剩余空间收缩、仍在 48–72 之间；16:9 的卡在真机上约 118×66。
    expect(card.height, inInclusiveRange(48, 72));
    expect(card.width / card.height, closeTo(16 / 9, .05));
    // 只留左半在屏内：卡片整体右移半宽，右半溢出屏幕。
    expect(card.left, closeTo(794 - card.width / 2, .01));
    expect(card.right, closeTo(794 + card.width / 2, .01));
    // 露出的那半截足够放下「下一集 / 第X集」，且满足 48dp 最小触控宽度。
    expect(794 - card.left, greaterThanOrEqualTo(48));
    expect(card.height, greaterThanOrEqualTo(48));
    // 读屏要念出集数（「下一集」三个字本身不含第几集），并且真的能激活：
    // `excludeSemantics` 会丢掉子树的 tap action，动作必须挂在 Semantics 上。
    // 这台播放器 currentIndex = 0，所以卡片是「第2集」。
    final semantics = tester.ensureSemantics();
    await tester.pump();
    final cardNode = tester.getSemantics(
      find.byKey(const ValueKey('landscape-next-card')),
    );
    expect(cardNode.label, '下一集，第2集');
    expect(cardNode.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
    // 封面按「三倍卡高」铺、上移一个卡高：窗口里只剩中间 1/3。
    final cover = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('landscape-next-card')),
        matching: find.byType(PlayerCover),
      ),
    );
    expect(cover.height, closeTo(card.height * 3, .01));
    expect(cover.top, closeTo(card.top - card.height, .01));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
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

/// 模拟「进全屏后设备横过来」：横屏布局只按窗口宽高判定，测试里得把窗口
/// 真的变宽，光点「全屏观看」不会改视口。
Future<void> _rotateToLandscape(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pump();
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
  VoidCallback? onOpenOfflineCache,
  VoidCallback? onToggleDanmaku,
  ValueChanged<DanmakuSettings>? onDanmakuSettingsChanged,
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
      onOpenOfflineCache: onOpenOfflineCache,
      qualityVariants: qualityVariants,
      currentQualityUrl: currentQualityUrl,
      onQualitySelected: qualitySelections?.add,
      onToggleDanmaku: onToggleDanmaku,
      onDanmakuSettingsChanged: onDanmakuSettingsChanged,
      child: const ColoredBox(color: Colors.black),
    ),
  ),
);
