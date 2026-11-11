import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:fqapp/pages/ai_reading/settings/developer_tools_page.dart';
import 'package:fqapp/services/ai_reading/ai_prompt.dart';
import 'package:fqapp/services/ai_reading/ai_settings.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final settings = AiSettingsStore.instance;
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('developer-tools-');
    Hive.init(directory.path);
    await settings.init();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() async {
    await settings.saveDevice(const AiDeviceSettings());
  });

  test('developer mode is device-local and defaults off for old settings', () {
    expect(AiDeviceSettings.fromJson({}).developerMode, isFalse);
    final device = const AiDeviceSettings().copyWith(developerMode: true);
    expect(AiDeviceSettings.fromJson(device.toJson()).developerMode, isTrue);
    expect(device.copyWith(cloudConsent: true).developerMode, isTrue);
    expect(device.copyWith(developerMode: false).developerMode, isFalse);
  });

  testWidgets('tools stay unavailable until developer mode is enabled', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: DeveloperToolsPage()));
    await tester.pumpAndSettle();
    expect(find.text('请先在 AI 设置 → 高级中开启开发者模式'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('prompt preview is the real request builder without duplicates', (
    tester,
  ) async {
    await tester.runAsync(
      () => settings.saveDevice(settings.device.copyWith(developerMode: true)),
    );
    await tester.pumpWidget(const MaterialApp(home: DeveloperToolsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('实际提示词与输出协议'));
    await tester.pumpAndSettle();
    final preview = tester
        .widget<SelectableText>(
          find.descendant(
            of: find.byType(ExpansionTile),
            matching: find.byType(SelectableText),
          ),
        )
        .data!;
    final expected = aiBuildSystemPrompt(
      behaviorPrompt: aiResolvePrompt(
        bookPrompt: null,
        globalPrompt: settings.global.behaviorPrompt,
      ).text,
      outputMode: AiOutputMode.jsonObject,
      restoreCensoredWords: true,
    );
    expect(preview, expected);
    // Each program-owned segment is shown exactly once, in priority order.
    expect(
      preview.indexOf(kAiPromptPrioritySection.trim()),
      lessThan(preview.indexOf(kAiBehaviorPromptSectionTitle)),
    );
    expect(
      preview.indexOf(kAiBehaviorPromptSectionTitle),
      lessThan(preview.indexOf(kAiRestoreCensoredWordsPrompt.trim())),
    );
    expect(
      preview.indexOf(kAiRestoreCensoredWordsPrompt.trim()),
      lessThan(preview.indexOf(kAiJsonObjectProtocol.trim())),
    );
    expect(kAiRestoreCensoredWordsPrompt.trim().allMatches(preview).length, 1);
    expect(kAiJsonObjectProtocol.trim().allMatches(preview).length, 1);
    expect(preview, isNot(contains('original 必须与提供的原文完全一致。')));
  });

  testWidgets(
    'offline response validation previews recovery without making an AI request',
    (tester) async {
      await tester.runAsync(
        () =>
            settings.saveDevice(settings.device.copyWith(developerMode: true)),
      );
      await tester.pumpWidget(const MaterialApp(home: DeveloperToolsPage()));
      await tester.pumpAndSettle();
      final jsonField = find.widgetWithText(TextField, '粘贴模型 JSON 响应（可离线测试）');
      await tester.scrollUntilVisible(
        jsonField,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        jsonField,
        '{"edits":[{"original":"wcnm","replacement":"还原词","category":"屏蔽词还原","reason":"测试"}]}',
      );
      final validate = find.text('离线校验与替换预览');
      await tester.ensureVisible(validate);
      await tester.tap(validate);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('developer-preview')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('developer-preview')),
            )
            .data,
        contains('还原词'),
      );
      expect(settings.device.cloudConsent, isFalse);
      expect(settings.global.enabled, isFalse);
    },
  );
}
