import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/ai_reading/settings/ai_settings_widgets.dart';

void main() {
  // 回归背景：showDialog 的 future 在 pop 生效时即完成（退出动画尚未播放），
  // 各弹窗随后立刻 controller.dispose()，而弹窗子树仍持有该 controller 直到
  // 退出动画结束才卸载。真机（Windows IME + 键盘动画）上会在卸载期间抛出
  // framework 断言，最终表现为 InheritedElement 的 _dependents.isEmpty 失败。
  // 本文件锁定关闭弹窗的完整时序，确保卸载不再产生异常。
  Future<void> pumpHost(WidgetTester tester, VoidCallback open) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: open, child: const Text('打开')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('cost dialog cancel keeps unmount clean', (tester) async {
    ({bool saved, double? value})? result;
    await pumpHost(tester, () async {
      result = await showAiCostDialog(
        tester.element(find.text('打开')),
        title: '每日费用上限',
        label: '金额',
        currency: '¥',
        initial: 3.5,
      );
    });
    expect(find.text('每日费用上限'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '3.5');
    await tester.tap(find.text('取消'));
    await tester.pump(); // pop 生效：future 完成，此时退出动画尚未结束
    await tester.pumpAndSettle(); // 退出动画播完，弹窗子树卸载
    expect(result!.saved, isFalse);
    expect(find.text('每日费用上限'), findsNothing);
  });

  testWidgets('cost dialog save keeps unmount clean', (tester) async {
    ({bool saved, double? value})? result;
    await pumpHost(tester, () async {
      result = await showAiCostDialog(
        tester.element(find.text('打开')),
        title: '每本书费用上限',
        label: '金额',
        currency: '¥',
        initial: 0,
      );
    });
    await tester.enterText(find.byType(TextField), '2.5');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(result!.saved, isTrue);
    expect(result!.value, 2.5);
    expect(find.text('每本书费用上限'), findsNothing);
  });

  testWidgets('limit dialog save keeps unmount clean', (tester) async {
    ({int tokens, int requests})? result;
    await pumpHost(tester, () async {
      result = await showAiLimitDialog(
        tester.element(find.text('打开')),
        title: '每日上限',
        tokenInitial: 1000,
        requestInitial: 10,
      );
    });
    await tester.enterText(find.byType(TextField).first, '2000');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(result!.tokens, 2000);
    expect(result!.requests, 10);
    expect(find.text('每日上限'), findsNothing);
  });

  testWidgets('int dialog cancel keeps unmount clean', (tester) async {
    int? result;
    await pumpHost(tester, () async {
      result = await showAiIntDialog(
        tester.element(find.text('打开')),
        title: '请求次数上限',
        label: '次数',
        initial: 20,
      );
    });
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('请求次数上限'), findsNothing);
  });

  testWidgets('secret dialog save keeps unmount clean', (tester) async {
    String? result;
    await pumpHost(tester, () async {
      result = await showAiSecretDialog(
        tester.element(find.text('打开')),
        title: 'API Key',
        hint: 'sk-...',
      );
    });
    expect(find.text('API Key'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'sk-test-123');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(result, 'sk-test-123');
    expect(find.text('API Key'), findsNothing);
  });
}
