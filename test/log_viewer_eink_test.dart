import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/log_viewer_page.dart';
import 'package:fqapp/services/app_log.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/home/home_chip.dart';

/// 日志页墨水屏回归：级别色、搜索框描边与筛选胶囊的选中可区分性。
void main() {
  setUp(() => AppLog.instance.resetForTest());
  tearDown(() => AppLog.instance.resetForTest());

  testWidgets('墨水屏下警告用黑色、搜索框保留可见描边', (tester) async {
    final original = einkModeNotifier.value;
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = original);
    AppLog.w('api', '接口超时');

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();

    final badge = tester.widget<Text>(find.text('警告'));
    expect(badge.style?.color, Colors.black, reason: 'e-ink warning is black');
    final field = tester.widget<TextField>(find.byType(TextField));
    final border = field.decoration?.enabledBorder;
    expect(border, isA<OutlineInputBorder>());
    expect(
      (border! as OutlineInputBorder).borderSide.color,
      Colors.black,
      reason: 'white search bar needs an outline on a white canvas',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('墨水屏下筛选弹层的选中与未选中胶囊可区分', (tester) async {
    final original = einkModeNotifier.value;
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = original);

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();
    await tester.tap(find.byTooltip('筛选日志'));
    await tester.pumpAndSettle();

    final selected = _chipDecoration(tester, '全部级别');
    final unselected = _chipDecoration(tester, '调试');
    expect(selected.color, Colors.black);
    expect((selected.shape as StadiumBorder).side, BorderSide.none);
    expect(unselected.color, Colors.white);
    expect((unselected.shape as StadiumBorder).side.color, Colors.black);
  });
}

ShapeDecoration _chipDecoration(WidgetTester tester, String label) {
  final chip = find.widgetWithText(HomeChip, label);
  final container = tester.widget<Container>(
    find.descendant(of: chip, matching: find.byType(Container)).first,
  );
  return container.decoration! as ShapeDecoration;
}
