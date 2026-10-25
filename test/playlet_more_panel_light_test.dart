import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/player/playlet_more_panel_light.dart';

void main() {
  testWidgets(
    'light panel shows a danmaku-settings row after the danmaku switch',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayletMorePanelLight(
              danmakuEnabled: true,
              onToggleDanmaku: () {},
              onOpenDanmakuSettings: () => opened++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('弹幕设置'), findsOneWidget);
      await tester.tap(find.text('弹幕设置'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'light panel hides the danmaku-settings row without its callback',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlayletMorePanelLight(
              danmakuEnabled: true,
              onToggleDanmaku: _noop,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('弹幕设置'), findsNothing);
      expect(find.text('弹幕'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tapping the danmaku row flips the switch in place', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletMorePanelLight(
            danmakuEnabled: true,
            onToggleDanmaku: () => toggles++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('player-more-light-danmaku-row'));
    expect(
      tester.getSemantics(row).flagsCollection.isToggled == ui.Tristate.isTrue,
      isTrue,
    );
    // 开关行不关闭面板：点完不重开面板，开关必须立刻显示关闭。
    await tester.tap(find.text('弹幕'));
    await tester.pump();
    expect(toggles, 1);
    expect(
      tester.getSemantics(row).flagsCollection.isToggled == ui.Tristate.isTrue,
      isFalse,
    );
    await tester.tap(find.text('弹幕'));
    await tester.pump();
    expect(toggles, 2);
    expect(
      tester.getSemantics(row).flagsCollection.isToggled == ui.Tristate.isTrue,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('danmaku switch follows externally updated enabled', (
    tester,
  ) async {
    var toggles = 0;
    // 父级在面板打开期间翻转 danmakuEnabled 并原地重建：开关必须跟随，
    // 否则之后每次点击都会与父级持续反向。
    Widget buildPanel({required bool enabled}) => MaterialApp(
      home: Scaffold(
        body: PlayletMorePanelLight(
          danmakuEnabled: enabled,
          onToggleDanmaku: () => toggles++,
        ),
      ),
    );
    await tester.pumpWidget(buildPanel(enabled: true));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('player-more-light-danmaku-row'));
    expect(
      tester.getSemantics(row).flagsCollection.isToggled == ui.Tristate.isTrue,
      isTrue,
    );
    await tester.pumpWidget(buildPanel(enabled: false));
    await tester.pump();
    expect(
      tester.getSemantics(row).flagsCollection.isToggled == ui.Tristate.isTrue,
      isFalse,
    );
    // 同步后点击应从父级当前值翻转，而不是从旧 State 的旧值翻转。
    await tester.tap(find.text('弹幕'));
    await tester.pump();
    expect(toggles, 1);
    expect(
      tester.getSemantics(row).flagsCollection.isToggled == ui.Tristate.isTrue,
      isTrue,
    );
    await tester.pumpWidget(buildPanel(enabled: true));
    await tester.pump();
    expect(
      tester.getSemantics(row).flagsCollection.isToggled == ui.Tristate.isTrue,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'danmaku switch starts off and follows externally updated enabled',
    (tester) async {
      Widget buildPanel({required bool enabled}) => MaterialApp(
        home: Scaffold(
          body: PlayletMorePanelLight(
            danmakuEnabled: enabled,
            onToggleDanmaku: () {},
          ),
        ),
      );
      await tester.pumpWidget(buildPanel(enabled: false));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('player-more-light-danmaku-row'));
      expect(
        tester.getSemantics(row).flagsCollection.isToggled ==
            ui.Tristate.isTrue,
        isFalse,
      );
      await tester.pumpWidget(buildPanel(enabled: true));
      await tester.pump();
      expect(
        tester.getSemantics(row).flagsCollection.isToggled ==
            ui.Tristate.isTrue,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rate and quality are entry rows, never inline pills', (
    tester,
  ) async {
    // feed 卡片没有播放页那条底栏，面板里留「倍速」「清晰度」入口行；
    // 档位本身不再内联铺开（药丸行/展开列表都撤了），点开走档位弹层。
    var rates = 0;
    var qualities = 0;
    Future<void> openPanel() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    // 入口行点击会先收起面板再交给宿主（级联开档位弹层），
                    // 所以面板得真的挂在一条路由上。
                    builder: (_) => PlayletMorePanelLight(
                      rateLabel: '1.25x',
                      onOpenRate: () => rates++,
                      qualityLabel: '720P',
                      onOpenQuality: () => qualities++,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    await openPanel();
    final panel = find.byKey(const ValueKey('player-more-light-panel'));
    expect(panel, findsOneWidget);
    expect(find.text('倍速'), findsOneWidget);
    expect(find.text('1.25x'), findsOneWidget);
    expect(find.text('清晰度'), findsOneWidget);
    expect(find.text('720P'), findsOneWidget);
    for (final label in ['0.75x', '1x', '1.5x', '2x', '3x']) {
      expect(find.text(label), findsNothing, reason: '$label 不该内联在面板里');
    }
    await tester.tap(find.text('倍速'));
    await tester.pumpAndSettle();
    expect(rates, 1);
    expect(panel, findsNothing);
    // 面板收起后重开，清晰度行走同一条路。
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清晰度'));
    await tester.pumpAndSettle();
    expect(qualities, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the entry rows disappear when the host has no use for them', (
    tester,
  ) async {
    // 播放页的「视频设置」不传这两个回调：底栏右下角已经显示当前档，
    // 点它直接开档位弹层，面板里不留第二个入口。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlayletMorePanelLight())),
    );
    await tester.pumpAndSettle();
    expect(find.text('倍速'), findsNothing);
    expect(find.text('清晰度'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the fill-screen row is not part of this panel', (tester) async {
    // 官方横屏截图的面板里没有这一行；浅色竖屏面板同样不放（保持一致）。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlayletMorePanelLight())),
    );
    await tester.pumpAndSettle();
    expect(find.text('画面撑满'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
