import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/fanqie_history_import_page.dart';
import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/settings/settings_adaptive.dart';
import 'package:fqapp/widgets/settings/settings_archive_page.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';

import 'support/app_ui_host.dart';

/// The 番茄 import page moved onto the Wenku8 archive shell while keeping its
/// source actions.
void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('${platform.name} 番茄导入页使用档案外壳，来源按钮保留', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        // The page asks the platform for the latest private capture on open; the
        // mock keeps that read synchronous and empty.
        const channel = MethodChannel('fqapp/library_backup');
        final calls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call.method);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(
          const MaterialApp(home: FanqieHistoryImportPage()),
        );
        await tester.pumpAndSettle();

        expect(calls, ['latestFanqieCapture']);
        expect(find.byType(SettingsArchivePage), findsOneWidget);
        expect(find.text('书架和进度，一起带回来'), findsOneWidget);
        expect(find.text('选择导入来源'), findsOneWidget);
        expect(find.text('从番茄账号读取'), findsOneWidget);
        expect(find.text('从历史文件导入'), findsOneWidget);
        expect(find.byType(SettingsSectionHeader), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('墨水屏模式把 eink=true 传给番茄登录', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
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
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final style in AppThemeStyle.values) {
    testWidgets('Linux ${style.name} 挂载及切换主题不读取采集或账号，文件立即可用', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        tester.view.physicalSize = const Size(500, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const files = MethodChannel('fqapp/library_backup');
        const account = MethodChannel('fqapp/fanqie_account');
        final fileCalls = <String>[];
        final accountCalls = <String>[];
        Object? response;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, (
          call,
        ) async {
          fileCalls.add(call.method);
          if (response is Exception) {
            throw response;
          }
          return response;
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          account,
          (call) async {
            accountCalls.add(call.method);
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            files,
            null,
          );
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            account,
            null,
          );
        });
        final store = AppThemeStyleStore()..value = style;
        addTearDown(store.dispose);
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(
          AppUiHost(store: store, home: const FanqieHistoryImportPage()),
        );

        final pick = find.byKey(const ValueKey('fanqie-pick'));
        final state = tester.state(find.byType(FanqieHistoryImportPage));
        expect(tester.widget<SettingsActionRow>(pick).enabled, isTrue);
        expect(fileCalls, isEmpty);
        expect(accountCalls, isEmpty);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.textContaining('Linux 仅支持导入已保存的番茄历史 JSON'), findsOneWidget);
        expect(find.byKey(const ValueKey('fanqie-collect')), findsNothing);
        expect(find.byTooltip('登录管理'), findsNothing);
        expect(find.text('最近一次采集'), findsNothing);
        expect(find.textContaining('网页登录状态保存在本应用中'), findsNothing);
        expect(find.textContaining('Linux 仅支持历史 JSON 文件导入'), findsOneWidget);

        // Null is picker cancellation; a malformed file and a picker failure
        // must both release busy state and leave a useful, credential-free message.
        await tester.tap(pick);
        await tester.pumpAndSettle();
        expect(find.text('已取消选择'), findsOneWidget);
        response = Uint8List.fromList([123]);
        await tester.ensureVisible(pick);
        await tester.tap(pick);
        await tester.pumpAndSettle();
        expect(find.text('文件不是有效的 UTF-8 JSON'), findsOneWidget);
        response = PlatformException(
          code: 'picker_failed',
          message: 'private-detail',
        );
        await tester.ensureVisible(pick);
        await tester.tap(pick);
        await tester.pumpAndSettle();
        expect(find.text('文件操作未完成，请重试'), findsOneWidget);
        expect(find.textContaining('private-detail'), findsNothing);
        response = MissingPluginException();
        await tester.ensureVisible(pick);
        await tester.tap(pick);
        await tester.pumpAndSettle();
        expect(find.text('当前环境无法选择文件，请检查桌面文件选择器后重试'), findsOneWidget);
        expect(tester.widget<SettingsActionRow>(pick).enabled, isTrue);
        expect(find.textContaining('导入预览'), findsNothing);

        for (final next in [
          style == AppThemeStyle.classic
              ? AppThemeStyle.archive
              : AppThemeStyle.classic,
          style,
        ]) {
          store.value = next;
          await tester.pumpAndSettle();
          expect(
            tester.state(find.byType(FanqieHistoryImportPage)),
            same(state),
          );
          expect(tester.widget<SettingsActionRow>(pick).enabled, isTrue);
          expect(find.text('当前环境无法选择文件，请检查桌面文件选择器后重试'), findsOneWidget);
          expect(find.byKey(const ValueKey('fanqie-collect')), findsNothing);
          expect(find.byTooltip('登录管理'), findsNothing);
        }
        expect(fileCalls, [
          'openBackup',
          'openBackup',
          'openBackup',
          'openBackup',
        ]);
        expect(accountCalls, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Linux ${style.name} 备份页番茄入口仅说明历史 JSON', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final store = AppThemeStyleStore()..value = style;
        addTearDown(store.dispose);
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(
          AppUiHost(store: store, home: const LibraryBackupPage()),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('backup-fanqie')),
          180,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('backup-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(find.text('仅支持已保存的番茄历史 JSON 文件'), findsOneWidget);
        expect(find.text('网页登录、最近采集和旧版历史文件'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
