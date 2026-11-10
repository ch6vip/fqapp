import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/fanqie_history_import_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

/// The 番茄 import page retains the archive shell and local file import,
/// without restoring removed account actions.
void main() {
  testWidgets('番茄导入页使用档案外壳，只保留本地导入来源', (tester) async {
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
    expect(find.text('从番茄账号读取'), findsNothing);
    expect(find.text('从历史文件导入'), findsOneWidget);
    expect(find.byType(SettingsSectionHeader), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('墨水屏模式使用本地文件导入，不调用账号登录', (tester) async {
    const account = MethodChannel('fqapp/fanqie_account');
    const files = MethodChannel('fqapp/library_backup');
    final loginCalls = <MethodCall>[];
    final fileCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, (
      call,
    ) async {
      fileCalls.add(call.method);
      return null;
    });
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
    await tester.tap(find.byKey(const ValueKey('fanqie-pick')));
    await tester.pumpAndSettle();

    expect(fileCalls, ['latestFanqieCapture', 'openBackup']);
    expect(loginCalls, isEmpty);
    expect(find.text('已取消选择'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
