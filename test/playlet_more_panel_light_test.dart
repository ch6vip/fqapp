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
}

void _noop() {}
