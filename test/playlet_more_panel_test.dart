import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/player_panel_preferences.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

/// F05 更多面板的开关行用例。
///
/// 官方依据：
/// - 画面撑满落 SP `is_fill_screen`，缺省 `!default_video_size_aspect_fit`
///   （`FillScreenDataManager.java:27-37`）
/// - 默认静音**不落盘**，只有 `tm3.b` 的静态字段，初始 true
///   （`tm3/b.java:17-20,58-83`）
/// - 两个开关行整行可点，Switch 自身不可点
///   （`ShortSeriesMorePanelDialogV2$ActionItemSingleChoiceHolder`）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 本套用例验的是深色 V2 面板（撑满/静音行、取消行、药丸拖选）；浅色
    // 分支（style 未下发，发布默认）另有用例覆盖。钉 style=1 走深色支。
    PlayerStyleConfig.instance = const PlayerStyleConfig(morePanelStyle: 1);
    PlayerPanelPreferences.setDefaultMute(true);
  });

  /// 深色 V2 是**底部 sheet** 形态（横屏右侧面板是另一套宫格，见
  /// video_player_chrome_test 的矮窗用例）。测试默认 surface 是 800×600，会被
  /// 判成横屏走到宫格上，所以每条 sheet 用例先钉成竖屏——`setSurfaceSize`
  /// 只能在用例体内调（在 `setUp` 里会触发 `inTest` 断言）。
  void sheetTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await body(tester);
    });
  }

  Widget app({
    FakeNativePlayer? nativePlayer,
    bool fillScreen = false,
    ValueChanged<bool>? onFill,
    bool defaultMute = true,
    ValueChanged<bool>? onMute,
    bool shortSeries = true,
    VoidCallback? onDanmaku,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    final player = nativePlayer ?? (FakeNativePlayer()..isPlaying = true);
    addTearDown(player.dispose);
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: VideoPlayerChrome(
          player: player,
          title: '剧',
          episodes: [Chapter(itemId: 'v1', title: '第一集', volumeName: '')],
          currentIndex: 0,
          duration: const Duration(minutes: 2),
          playing: player.isPlaying,
          shortSeries: shortSeries,
          fillScreen: fillScreen,
          onFillScreenChanged: onFill,
          defaultMute: defaultMute,
          onDefaultMuteChanged: onMute,
          onToggleDanmaku: onDanmaku,
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

  sheetTest('the panel carries the fill-screen and mute rows', (tester) async {
    await tester.pumpWidget(app(onFill: (_) {}, onMute: (_) {}));
    await tester.pumpAndSettle();
    await openMore(tester);
    expect(find.text('画面撑满'), findsOneWidget);
    expect(find.text('默认静音'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-more-fill-switch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-more-mute-switch')),
      findsOneWidget,
    );
  });

  sheetTest('the rows disappear without their callbacks', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await openMore(tester);
    expect(find.text('画面撑满'), findsNothing);
    expect(find.text('默认静音'), findsNothing);
  });

  sheetTest('tapping the whole row toggles the switch', (tester) async {
    final fills = <bool>[];
    final mutes = <bool>[];
    await tester.pumpWidget(
      app(
        fillScreen: false,
        onFill: fills.add,
        defaultMute: true,
        onMute: mutes.add,
      ),
    );
    await tester.pumpAndSettle();
    await openMore(tester);
    // 官方整行承载点击（SwitchButtonV2 自己 setClickable(false)）。
    await tester.tap(find.byKey(const ValueKey('player-more-fill-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-more-mute-row')));
    await tester.pumpAndSettle();
    expect(fills, [true]);
    expect(mutes, [false]);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('player-more-fill-row'))),
      matchesSemantics(
        label: '画面撑满',
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
    );
    // 点开关图形仍由整行处理，每次只触发一次。
    await tester.tap(find.byKey(const ValueKey('player-more-fill-switch')));
    await tester.pumpAndSettle();
    expect(fills, [true, false]);
    expect(find.byKey(const ValueKey('player-more-panel')), findsOneWidget);
  });

  sheetTest('retained options follow the official groups and action order', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(onFill: (_) {}, onMute: (_) {}, onDanmaku: () {}),
    );
    await tester.pumpAndSettle();
    await openMore(tester);
    final positions = [
      for (final id in ['fill', 'mute', 'danmaku'])
        tester.getTopLeft(find.byKey(ValueKey('player-more-$id-row'))).dy,
    ];
    expect(positions, orderedEquals([...positions]..sort()));
    // 官方 aae.xml 底部整行「取消」（@string/biu）。
    expect(find.text('取消'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('分享'), findsNothing);
    // 倍速入口全页只有一个：这套用例的 surface 是竖屏 catalog 形态，底栏
    // 不显示当前档，入口就留在面板里（点开档位弹层）。
    final panel = find.byKey(const ValueKey('player-more-panel'));
    expect(find.byKey(const ValueKey('player-more-rate-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-rate-text')), findsNothing);
    // 档位不再内联铺在面板里：只剩行尾那一个当前档文案。
    expect(find.byKey(const ValueKey('player-more-rate-scroll')), findsNothing);
    expect(
      find.descendant(of: panel, matching: find.text('0.75x')),
      findsNothing,
      reason: '0.75x 档位不该内联在视频设置里',
    );
    expect(
      find.byKey(const ValueKey('player-more-rate-value')),
      findsOneWidget,
    );
  });

  sheetTest('the bottom-bar rate opens its own sheet and persists the pick', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(app(nativePlayer: player));
    await tester.pumpAndSettle();
    // 底栏「倍速」文字只在清屏态出现（官方：清屏后留这一个入口），它开的
    // 是档位弹层，不是视频设置面板。
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    player.calls.clear();
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-more-panel')), findsNothing);
    expect(find.byKey(const ValueKey('player-rate-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-rate-sheet-4')));
    await tester.pumpAndSettle();
    expect(player.calls, ['rate:2.0']);
    expect(await PlayerPreferences.loadPlaybackRate(), 2);
    expect(find.byKey(const ValueKey('player-rate-sheet')), findsNothing);

    // 换播放器（下一集/重进播放页）沿用已保存的档位，弹层里标的也是它。
    await tester.pumpWidget(const SizedBox.shrink());
    final next = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(app(nativePlayer: next));
    await tester.pumpAndSettle();
    expect(next.rate, 2);
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-rate-sheet-4')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
  });

  sheetTest('back on the rate sheet applies nothing and keeps the player', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(app(nativePlayer: player));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    player.calls.clear();
    await tester.tap(find.byKey(const ValueKey('player-rate-text')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlayerChrome), findsOneWidget);
    expect(find.byKey(const ValueKey('player-rate-sheet')), findsNothing);
    expect(player.calls, isEmpty);
    expect(await PlayerPreferences.loadPlaybackRate(), 1);
    expect(tester.takeException(), isNull);
  });

  for (final dismissal in ['outside', 'back', 'swipe']) {
    sheetTest(
      '$dismissal closes only the sheet and preserves paused clear screen',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final player = FakeNativePlayer()..isPlaying = false;
        final position = player.position;
        await tester.pumpWidget(app(nativePlayer: player));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
        await tester.pump();
        // 清屏态下唯一的设置入口是底栏「倍速」文字，它开的是档位弹层。
        await tester.tap(find.byKey(const ValueKey('player-rate-text')));
        await tester.pumpAndSettle();
        player.calls.clear();
        switch (dismissal) {
          case 'outside':
            await tester.tapAt(const Offset(200, 180));
          case 'back':
            await tester.binding.handlePopRoute();
          case 'swipe':
            await tester.fling(
              find.byKey(const ValueKey('player-option-drag-handle')),
              const Offset(0, 250),
              1200,
            );
        }
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        expect(find.byKey(const ValueKey('player-rate-sheet')), findsNothing);
        expect(find.text('恢复'), findsOneWidget);
        expect(player.calls, isEmpty);
        expect(player.isPlaying, isFalse);
        expect(player.position, position);
        await tester.tap(find.text('恢复'));
        await tester.pump();
        expect(find.byTooltip('更多'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  sheetTest(
    'rotation resizes the sheet and keeps switch state and reachability',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fills = <bool>[];
      var danmakuToggles = 0;
      await tester.pumpWidget(
        app(
          onFill: fills.add,
          onMute: (_) {},
          onDanmaku: () => danmakuToggles++,
        ),
      );
      await tester.pumpAndSettle();
      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('player-more-fill-row')));
      await tester.pumpAndSettle();
      for (final size in [const Size(800, 360), const Size(360, 800)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        final bounds = tester.getRect(
          find.byKey(const ValueKey('player-more-panel')),
        );
        expect(bounds.width, size.width);
        expect(bounds.height, lessThanOrEqualTo(size.height * .6));
        expect(bounds.bottom, size.height);
        expect(
          tester
              .widget<Semantics>(
                find.byKey(const ValueKey('player-more-fill-row')),
              )
              .properties
              .toggled,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey('player-more-danmaku-row')),
      );
      await tester.tap(find.byKey(const ValueKey('player-more-danmaku-row')));
      await tester.pumpAndSettle();
      expect(danmakuToggles, 1);
      expect(fills, [true]);
    },
  );

  sheetTest('large text in a short window keeps all local controls reachable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final mutes = <bool>[];
    var danmakuToggles = 0;
    await tester.pumpWidget(
      app(
        textScaler: TextScaler.linear(2.5),
        onFill: (_) {},
        onMute: mutes.add,
        onDanmaku: () => danmakuToggles++,
      ),
    );
    await tester.pumpAndSettle();
    await openMore(tester);
    for (final id in ['mute', 'danmaku']) {
      final row = find.byKey(ValueKey('player-more-$id-row'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
    }
    expect(mutes, [false]);
    expect(danmakuToggles, 1);
    // 面板里只有倍速「入口行」，没有内联档位：大字号下面板不会被药丸行
    // 撑高到滚不到底，开关行仍都点得到。
    final panel = find.byKey(const ValueKey('player-more-panel'));
    expect(
      find.descendant(of: panel, matching: find.text('倍速')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('0.75x')),
      findsNothing,
    );
    expect(find.descendant(of: panel, matching: find.text('3x')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('fill screen follows the official portrait default', () async {
    // 官方：竖屏且 SP 无键 -> false（FillScreenDataManager.java:29-32）。
    expect(await PlayerPanelPreferences.loadFillScreen(), isFalse);
    // 非竖屏才用 !default_video_size_aspect_fit（配置缺省 false -> true）。
    expect(
      await PlayerPanelPreferences.loadFillScreen(portrait: false),
      isTrue,
    );
    await PlayerPanelPreferences.saveFillScreen(true);
    expect(await PlayerPanelPreferences.loadFillScreen(), isTrue);
  });

  test('the fill-screen default follows the official config key', () async {
    PlayerStyleConfig.instance = const PlayerStyleConfig(
      defaultVideoSizeAspectFit: true,
    );
    expect(
      await PlayerPanelPreferences.loadFillScreen(portrait: false),
      isFalse,
    );
  });

  test('default mute is memory-only and starts enabled', () {
    // 官方不落盘（tm3/b 的静态字段），重启回到初始值。
    expect(PlayerPanelPreferences.defaultMute, isTrue);
    PlayerPanelPreferences.setDefaultMute(false);
    expect(PlayerPanelPreferences.defaultMute, isFalse);
  });
}
