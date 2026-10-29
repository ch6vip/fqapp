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
}
