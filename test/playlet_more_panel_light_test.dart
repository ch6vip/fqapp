import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/player/playlet_more_panel_light.dart';

void main() {
  testWidgets('light panel shows a danmaku-settings row after the danmaku switch', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletMorePanelLight(
            rate: 1,
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
  });

  testWidgets('light panel hides the danmaku-settings row without its callback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayletMorePanelLight(
            rate: 1,
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
  });

  testWidgets('tapping the danmaku row flips the switch in place', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletMorePanelLight(
            rate: 1,
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
          rate: 1,
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

  testWidgets('danmaku switch starts off and follows externally updated enabled', (
    tester,
  ) async {
    Widget buildPanel({required bool enabled}) => MaterialApp(
      home: Scaffold(
        body: PlayletMorePanelLight(
          rate: 1,
          danmakuEnabled: enabled,
          onToggleDanmaku: () {},
        ),
      ),
    );
    await tester.pumpWidget(buildPanel(enabled: false));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('player-more-light-danmaku-row'));
    expect(
      tester.getSemantics(row).flagsCollection.isToggled == ui.Tristate.isTrue,
      isFalse,
    );
    await tester.pumpWidget(buildPanel(enabled: true));
    await tester.pump();
    expect(
      tester.getSemantics(row).flagsCollection.isToggled == ui.Tristate.isTrue,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
