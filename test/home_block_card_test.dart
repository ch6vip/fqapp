import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/home/home_shelf.dart';

// `homeShelfColumns`：书架网格的列数。手机 3 列（≥360dp 内容宽），小屏和
// 大字号退回 2 列；平板/桌面按宽度放宽。
void main() {
  late BuildContext context;

  Future<void> pump(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox();
          },
        ),
      ),
    );
  }

  testWidgets('a phone holds three columns, a narrow one holds two', (
    tester,
  ) async {
    await pump(tester);

    // 400dp 屏减去 16dp 栏距后内容宽 368。
    expect(homeShelfColumns(context, 368), 3);
    // 320dp 屏内容宽 288：三列时书名只剩四五个字，退到两列。
    expect(homeShelfColumns(context, 288), 2);
  });

  testWidgets('large type drops a 400-wide phone to two columns', (
    tester,
  ) async {
    await pump(tester, textScale: 1.8);
    expect(homeShelfColumns(context, 368), 2);
  });

  testWidgets('tablets and desktop widen the grid', (tester) async {
    await pump(tester);
    expect(homeShelfColumns(context, 700), 4);
    expect(homeShelfColumns(context, 950), 5);
  });

  testWidgets('宽屏按目标卡宽反推列数，卡片不会被拉胖', (tester) async {
    await pump(tester);

    // 840 的上限被拆掉之后，2560 的窗口里内容宽约 2528：13 列，一张卡
    // 186dp。旧断点在 900dp 之后就到顶（5 列），这个宽度下会给出 5 列、
    // 一张封面 500dp 宽。
    expect(homeShelfColumns(context, 2528), 13);

    // 无论窗口多宽，卡片都停在 180dp 上下——这是「可读」的那条线：
    // 再窄书名只剩三四个字，再胖封面就变成海报。
    for (final width in <double>[900, 1408, 2528, 3808]) {
      final card = homeShelfCardWidth(context, width);
      expect(card, greaterThan(165), reason: '$width 宽时卡片被压窄');
      expect(card, lessThan(195), reason: '$width 宽时卡片被拉胖');
    }
  });
}
