import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/pages/ai_reading/settings/ai_settings_page.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/ai_reading/ai_controller.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/ai_reading/ai_settings.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';

import '../support/secure_key_storage_mock.dart';

/// The consent row is a single withdraw-only entry shown only after consent was
/// granted from the AI master switch dialog. Persisted settings serialise writes,
/// so this file keeps one consent state and walks grant -> withdraw in order.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final settings = AiSettingsStore.instance;

  setUpAll(() async {
    mockSecureKeyStorage();
    directory = await Directory.systemTemp.createTemp('ai-settings-consent-');
    Hive.init(directory.path);
    await settings.init();
    await settings.saveDevice(const AiDeviceSettings(cloudConsent: true));
    await settings.saveGlobal(const AiGlobalSettings());
    // The page kicks off the controller itself; doing it here keeps the widget
    // test free of real file I/O while it pumps.
    await AiReadingController.instance.init();
  });
  tearDownAll(() async {
    await Hive.close().timeout(const Duration(seconds: 5));
    await directory.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    // Explicit short timeout so a runaway frame loop fails instead of blocking
    // for pumpAndSettle's ten-minute default.
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiSettingsPage()));
    await settle(tester);
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      280,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(tester);
  }

  testWidgets('authorization row is withdraw-only and granting stays in the '
      'master switch dialog', (tester) async {
    await pumpPage(tester);

    // The optional feature copy stays short.
    await scrollTo(tester, find.text('去屏蔽词'));
    expect(find.text('根据上下文补全屏蔽词和谐音替换词'), findsOneWidget);

    await scrollTo(tester, find.text('正文上传授权'));

    // Granted: exactly one row with only a withdraw action.
    expect(find.text('正文上传授权'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
    expect(find.text('云端正文传输'), findsNothing);
    expect(find.text('已同意'), findsNothing);
    expect(find.text('未同意'), findsNothing);
    expect(find.text('去同意'), findsNothing);

    // The backup row no longer claims a value.
    expect(find.text('AI 数据备份'), findsOneWidget);
    expect(
      tester
          .widget<SettingsRow>(
            find.ancestor(
              of: find.text('AI 数据备份'),
              matching: find.byType(SettingsRow),
            ),
          )
          .value,
      isNull,
    );
    expect(find.text('包含'), findsNothing);

    // Withdraw still confirms, then the row disappears with the consent.
    // Invoke the actual asynchronous button callback in the real zone. Pointer
    // dispatch uses the gesture binding's fake zone even inside runAsync, so
    // await the callback itself after confirming rather than guessing I/O time.
    final withdraw =
        tester
                .widget<TextButton>(find.widgetWithText(TextButton, '撤销'))
                .onPressed!
            as Future<void> Function();
    late Future<void> withdrawal;
    await tester.runAsync(() async {
      withdrawal = withdraw();
    });
    await settle(tester);
    expect(find.text('撤回云端正文传输同意？'), findsOneWidget);
    await tester.tap(find.text('撤回同意'));
    await tester.runAsync(() => withdrawal.timeout(const Duration(seconds: 5)));
    await settle(tester);
    expect(settings.device.cloudConsent, isFalse);
    expect(find.text('正文上传授权'), findsNothing);
    expect(find.text('撤销'), findsNothing);
    expect(find.text('去同意'), findsNothing);

    // Consent can only be granted again from the master switch dialog.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await settle(tester);
    // The master switch lives in the summary card, which is first on the page.
    await tester.tap(find.byType(Switch).first);
    await settle(tester);
    expect(find.text('把章节正文发给第三方？'), findsOneWidget);
    await tester.tap(find.text('暂不开启'));
    await settle(tester);
    expect(settings.device.cloudConsent, isFalse);
    expect(settings.global.enabled, isFalse);

    // Remove listeners before closing the real box, then reopen it to verify
    // consent survived on disk rather than just in the settings singleton.
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    await tester.runAsync(() async {
      await EncryptedHive.box<dynamic>(
        Hive,
        AiSettingsStore.boxName,
      ).close().timeout(const Duration(seconds: 5));
      final reopened = await EncryptedHive.openBox<dynamic>(
        Hive,
        AiSettingsStore.boxName,
        requireEncryption: true,
      );
      expect((reopened.get('device') as Map)['cloudConsent'], isFalse);
    });
  });
}
