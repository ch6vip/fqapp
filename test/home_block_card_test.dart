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

  testWidgets('宽屏由六列长到九列封顶，再多出的宽度给卡片', (tester) async {
    await pump(tester);

    // 与短剧页同一口径（一格 190dp）：默认窗口六列，全屏九列封顶。
    // 内容宽 = 窗口宽 - 32dp 栏距。
    expect(homeShelfColumns(context, 1172), 6);
    expect(homeShelfColumns(context, 1376), 7);
    expect(homeShelfColumns(context, 1900), 9);
    expect(homeShelfColumns(context, 2528), 9);
    // 3808（5K 全屏）也不超过九列——宽度增长归卡片，不再往格子里塞书。
    expect(homeShelfColumns(context, 3808), 9);

    // 列数封顶后卡片随窗口变大：全屏一张 ≈ 270dp，是默认窗口的 1.4 倍。
    final standard = homeShelfCardWidth(context, 1172);
    final fullscreen = homeShelfCardWidth(context, 2528);
    expect(standard, greaterThan(178));
    expect(standard, lessThan(192));
    expect(fullscreen, greaterThan(standard * 1.4));

    // 900–1130 这一段还没到六列的宽度，保持平板五列，否则一张卡只剩 140dp。
    expect(homeShelfColumns(context, 900), 5);
    expect(homeShelfColumns(context, 1100), 5);
  });
}
