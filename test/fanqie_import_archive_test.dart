import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/fanqie_history_import_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

/// The 番茄 import page moved onto the Wenku8 archive shell while keeping its
/// source actions.
void main() {
  testWidgets('番茄导入页使用档案外壳，来源按钮保留', (tester) async {
    // The page asks the platform for the latest private capture on open; the
    // mock keeps that read synchronous and empty.
    const channel = MethodChannel('fqapp/library_backup');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: FanqieHistoryImportPage()));
    await tester.pumpAndSettle();

    expect(find.byType(ArchiveFeaturePage), findsOneWidget);
    expect(find.text('书架和进度，一起带回来'), findsOneWidget);
    expect(find.text('选择导入来源'), findsOneWidget);
    expect(find.text('从番茄账号读取'), findsOneWidget);
    expect(find.text('从历史文件导入'), findsOneWidget);
    expect(find.byType(SettingsSectionHeader), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('墨水屏模式把 eink=true 传给番茄登录', (tester) async {
    const account = MethodChannel('fqapp/fanqie_account');
    const files = MethodChannel('fqapp/library_backup');
    final loginCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      files,
      (call) async => null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(account, (
      call,
    ) async {
      if (call.method == 'login') loginCalls.add(call);
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        account,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        files,
        null,
      );
    });
    final original = einkModeNotifier.value;
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = original);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light, einkMode: true),
        home: const FanqieHistoryImportPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fanqie-collect')));
    await tester.pumpAndSettle();

    expect(loginCalls, hasLength(1));
    final arguments = loginCalls.single.arguments as Map;
    expect(arguments['eink'], isTrue, reason: '原生登录页要切换纯白/纯黑');
    expect(arguments['dark'], isFalse);
  });
}
