import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/home/home_cell_blocks.dart';

// `homeColumnCount`：书卡网格列数（`us3.a.q()` 直译，平板断点）。
// 其余 S1 白卡断言已随白卡管线删除（流区块改为裸网格对齐官方）。

void main() {
  late BuildContext context;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox();
          },
        ),
      ),
    );
  }

  testWidgets('phone keeps 2 columns, pads follow the breakpoints', (
    tester,
  ) async {
    await pump(tester);

    // `b()` 平板适配开关关着，手机恒 2 列。
    expect(homeColumnCount(context), 2);
    // 默认测试面 800×600：短边 600 落在 [516, 1024)。
    expect(homeColumnCount(context, padAdapt: true), 3);
  });

  testWidgets('windows desktop widens the stream instead of 2 columns', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pump(tester);
      // 平板适配开关不覆盖桌面：桌面窗口若死守 2 列，1280 宽下每张卡
      // 570dp、封面 1.4 高，两张卡就吃掉一整屏。桌面按同一套断点走。
      expect(homeColumnCount(context), greaterThan(2));
      expect(homeColumnCount(context), 3);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
