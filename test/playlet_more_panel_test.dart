import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/player_panel_preferences.dart';
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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlayerStyleConfig.instance = PlayerStyleConfig.defaults;
    PlayerPanelPreferences.setDefaultMute(true);
  });

  Widget app({
    bool fillScreen = false,
    ValueChanged<bool>? onFill,
    bool defaultMute = true,
    ValueChanged<bool>? onMute,
    bool shortSeries = true,
  }) {
    final player = FakeNativePlayer()..isPlaying = true;
    addTearDown(player.dispose);
    return MaterialApp(
      home: Scaffold(
        body: VideoPlayerChrome(
          player: player,
          title: '剧',
          episodes: [Chapter(itemId: 'v1', title: '第一集', volumeName: '')],
          currentIndex: 0,
          duration: const Duration(minutes: 2),
          playing: true,
          shortSeries: shortSeries,
          fillScreen: fillScreen,
          onFillScreenChanged: onFill,
          defaultMute: defaultMute,
          onDefaultMuteChanged: onMute,
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

  testWidgets('the panel carries the fill-screen and mute rows', (tester) async {
    await tester.pumpWidget(app(onFill: (_) {}, onMute: (_) {}));
    await tester.pumpAndSettle();
    await openMore(tester);
    expect(find.text('画面撑满'), findsOneWidget);
    expect(find.text('默认静音'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-more-fill-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-more-mute-switch')), findsOneWidget);
  });

  testWidgets('the rows disappear without their callbacks', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await openMore(tester);
    expect(find.text('画面撑满'), findsNothing);
    expect(find.text('默认静音'), findsNothing);
  });

  testWidgets('tapping the whole row toggles the switch', (tester) async {
    final fills = <bool>[];
    final mutes = <bool>[];
    await tester.pumpWidget(
      app(fillScreen: false, onFill: fills.add, defaultMute: true, onMute: mutes.add),
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
