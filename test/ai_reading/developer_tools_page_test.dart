import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/pages/ai_reading/settings/developer_tools_page.dart';
import 'package:fqapp/pages/ai_reading/settings/ai_sandbox_widgets.dart';
import 'package:fqapp/pages/ai_reading/settings/ai_sandbox_request_page.dart';
import 'package:fqapp/services/ai_reading/ai_client.dart';
import 'package:fqapp/services/ai_reading/ai_controller.dart';
import 'package:fqapp/services/ai_reading/ai_coordinator.dart';
import 'package:fqapp/services/ai_reading/ai_credentials.dart';
import 'package:fqapp/services/ai_reading/ai_prompt.dart';
import 'package:fqapp/services/ai_reading/ai_settings.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/pages/ai_reading/settings/ai_sandbox_style.dart';

import '../support/secure_key_storage_mock.dart';

/// Controllable HTTP/SSE transport. Cancellation is delivered through the same
/// AbortableRequest used in production, without a network or paid credential.
class _SseClient extends http.BaseClient {
  final received = Completer<void>();
  final aborted = Completer<void>();
  final stream = StreamController<List<int>>();
  Map<String, dynamic>? body;
  int calls = 0;
  bool _ended = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    body = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
    (request as http.AbortableRequest).abortTrigger?.then((_) {
      if (!aborted.isCompleted) aborted.complete();
      if (!_ended) {
        _ended = true;
        stream.addError(http.RequestAbortedException(request.url));
        unawaited(stream.close());
      }
    });
    if (!received.isCompleted) received.complete();
    return http.StreamedResponse(
      stream.stream,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  void event(Map<String, dynamic> value) =>
      stream.add(utf8.encode('data: ${jsonEncode(value)}\n\n'));
  void delta(String text, {bool reasoning = false}) => event({
    'choices': [
      {
        'delta': {reasoning ? 'reasoning_content' : 'content': text},
      },
    ],
  });
  Future<void> finish({String reason = 'stop', bool usage = true}) async {
    event({
      'choices': [
        {'delta': {}, 'finish_reason': reason},
      ],
      if (usage)
        'usage': {
          'prompt_tokens': 120,
          'completion_tokens': 30,
          'total_tokens': 150,
        },
    });
    stream.add(utf8.encode('data: [DONE]\n\n'));
    _ended = true;
    await stream.close();
  }
}

class _DialogObserver extends NavigatorObserver {
  final shown = Completer<void>();
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute && !shown.isCompleted) shown.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final settings = AiSettingsStore.instance;
  setUpAll(() async {
    mockSecureKeyStorage();
    directory = await Directory.systemTemp.createTemp('ai-console-');
    Hive.init(directory.path);
    await settings.init();
    await AiReadingController.instance.init();
    await settings.upsertProvider(
      AiProviderProfile(
        id: 'fixture',
        label: 'Fixture',
        baseUrl: 'https://fixture.invalid/v1',
        credentialRef: 'fixture-key',
        outputMode: AiOutputMode.jsonObject,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    await AiCredentialStore.instance.write('fixture-key', 'test-key');
  });
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/ai_request'),
          (call) async => call.method == 'acquire' ? 'fixture-lease' : null,
        );
    await settings.saveDevice(const AiDeviceSettings(cloudConsent: true));
    await settings.saveGlobal(
      const AiGlobalSettings(
        enabled: true,
        providerId: 'fixture',
        modelId: 'fixture-model',
        behaviorPrompt: '全局校对规则',
        restoreCensoredWords: true,
      ),
    );
  });
  tearDownAll(() async {
    await Hive.close().timeout(const Duration(seconds: 5));
    await directory.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
  Future<void> open(
    WidgetTester tester, {
    _SseClient? client,
    ThemeData? theme,
    NavigatorObserver? observer,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [?observer],
        theme: theme ?? ThemeData(extensions: [const AppStyleTokens.classic()]),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DeveloperToolsPage(
                    coordinator: client == null
                        ? null
                        : AiCoordinator(
                            client: AiChatCompletionsClient(client: client),
                          ),
                  ),
                ),
              ),
              child: const Text('打开测试台'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开测试台'));
    await settle(tester);
  }

  Future<void> visible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await settle(tester);
  }

  Future<void> jsonPage(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多工具'));
    await settle(tester);
    await tester.tap(find.text('JSON 校验'));
    await settle(tester);
  }

  testWidgets(
    'classic scoped console and child pages clear the actual AppBar once',
    (tester) async {
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewPadding);
      final style = AppThemeStyleStore()..value = AppThemeStyle.classic;
      addTearDown(style.dispose);
      Widget app() => MaterialApp(
        theme: ThemeData(
          extensions: [
            style.value == AppThemeStyle.classic
                ? const AppStyleTokens.classic()
                : const AppStyleTokens.archive(),
          ],
        ),
        builder: (context, child) => AppUiScope(store: style, child: child!),
        home: const DeveloperToolsPage(),
      );
      await tester.pumpWidget(app());
      await settle(tester);
      final gaps = <String, double>{};
      double gap(Finder content) =>
          tester.getTopLeft(content).dy -
          tester.getBottomLeft(find.byType(AppBar)).dy;
      gaps['console'] = gap(
        find.byKey(const ValueKey('sandbox-provider-summary')),
      );
      await jsonPage(tester);
      gaps['json'] = gap(find.byType(AiSandboxField).first);
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      await tester.tap(find.text('查看请求'));
      await settle(tester);
      gaps['request'] = gap(find.byType(AiSandboxTabs));
      expect(find.text('当前配置预览'), findsNothing);
      expect(find.text('本次请求快照'), findsNothing);
      expect(find.text('Fixture / fixture-model'), findsNothing);
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      await tester.tap(find.text('行为提示词'));
      await settle(tester);
      final promptPanel = find.byKey(const ValueKey('sandbox-prompt-panel'));
      gaps['editor'] = gap(promptPanel);
      expect(gaps['editor'], 16);
      final footer = tester.getRect(
        find.byKey(const ValueKey('sandbox-prompt-toolbar')),
      );
      expect(footer.height, 44);
      expect(footer.bottom, 1000 - 34 - 16);
      expect(footer.top - tester.getRect(promptPanel).bottom, 12);
      // Record all three first, so a failure identifies each page's real inset.
      debugPrint(jsonEncode(gaps));
      for (final entry in gaps.entries) {
        expect(
          entry.value,
          entry.key == 'request' ? closeTo(0, 1) : inInclusiveRange(12, 18),
          reason: entry.key,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      style.value = AppThemeStyle.archive;
      await tester.pumpWidget(app());
      await settle(tester);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('sandbox-provider-summary')))
            .dy,
        inInclusiveRange(100, 108),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await settle(tester);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('sandbox-provider-summary')))
            .dy,
        inInclusiveRange(100, 108),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets(
    'provider summary keeps the prototype hierarchy at narrow widths',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final classic in [true, false]) {
        for (final dark in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                extensions: [
                  classic
                      ? const AppStyleTokens.classic()
                      : const AppStyleTokens.archive(),
                ],
              ),
              home: Scaffold(
                body: MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: AiSandboxProviderSummary(
                      provider: 'DeepSeek compatible custom provider',
                      model: 'deepseek-flash-long-model-name',
                      onViewRequest: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await settle(tester);
          final provider = tester.widget<Text>(
            find.text('DeepSeek compatible custom provider'),
          );
          final model = tester.widget<Text>(
            find.text('deepseek-flash-long-model-name'),
          );
          expect(provider.style!.fontSize, 13);
          expect(provider.style!.fontWeight, FontWeight.w500);
          expect(model.style!.fontSize, 12);
          expect(model.style!.color, isNot(provider.style!.color));
          expect(find.byType(Icon), findsOneWidget);
          expect(
            tester.getRect(find.byType(Icon)).right,
            lessThan(tester.getRect(find.text(provider.data!)).left),
          );
          expect(find.text('查看请求').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets('prototype field geometry and responsive columns stay aligned', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester);
    final summary = tester.getRect(find.byType(AiSandboxProviderSummary));
    final field = tester.getRect(find.byType(AiSandboxField));
    final panel = tester.getRect(find.byType(AiSandboxPanel));
    expect(field.top - summary.bottom, 6);
    expect(panel.top - field.top, 42);
    expect(panel.height, inInclusiveRange(210, 216));
    expect(panel.left, 16);
    expect(tester.getSize(find.byType(AiSandboxRestoreOption)).height, 64);
    final decoration =
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byType(AiSandboxPanel),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(12));
    expect((decoration.border! as Border).top.width, 1);
    expect(tester.widget<TextField>(find.byType(TextField)).minLines, 7);
    await jsonPage(tester);
    expect(tester.widget<TextField>(find.byType(TextField).first).minLines, 4);
    final response = tester.widget<TextField>(find.byType(TextField).last);
    expect(response.minLines, 8);
    expect(response.style!.fontFamily, 'monospace');
    expect(response.style!.fontSize, 13);
    await tester.tap(find.byTooltip('返回'));
    await settle(tester);
    tester.view.physicalSize = const Size(1024, 768);
    await settle(tester);
    expect(tester.getRect(find.byType(AiSandboxField)).left, 28);
    expect(
      tester.getRect(find.byType(AiSandboxPanel)).height,
      greaterThanOrEqualTo(240),
    );
    final input = tester.getRect(find.byType(AiSandboxField));
    final empty = tester.getRect(find.text('测试结果将在这里显示'));
    expect(empty.left, greaterThanOrEqualTo(input.right + 40));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

  testWidgets(
    'all field actions stay at the right edge at normal and large text sizes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      void expectActionsRight() {
        for (final field in find.byType(AiSandboxField).evaluate()) {
          final fieldFinder = find.byWidget(field.widget);
          final action = find.descendant(
            of: fieldFinder,
            matching: find.byType(TextButton),
          );
          expect(
            tester.getRect(action).right,
            closeTo(tester.getRect(fieldFinder).right, .1),
          );
        }
        expect(tester.takeException(), isNull);
      }

      for (final largeText in [false, true]) {
        tester.view.physicalSize = Size(largeText ? 320 : 411, 914);
        tester.platformDispatcher.textScaleFactorTestValue = largeText ? 2 : 1;
        await open(tester);
        expectActionsRight();
        final menu = find.byIcon(Icons.more_horiz);
        expect(menu.hitTestable(), findsOneWidget);
        expect(
          tester.getSize(find.byTooltip('更多工具')).shortestSide,
          greaterThanOrEqualTo(44),
        );
        await jsonPage(tester);
        expectActionsRight();
        await visible(tester, find.text('使用测试正文'));
        await tester.tap(find.text('使用测试正文'));
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          aiSandboxSample,
        );
        await visible(tester, find.widgetWithText(TextButton, '填入示例'));
        await tester.tap(find.widgetWithText(TextButton, '填入示例'));
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          aiSandboxExampleResponse,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
      }
    },
  );

  testWidgets('prompt source is inline and primary action fills input column', (
    tester,
  ) async {
    await open(tester);
    final title = tester.getRect(find.text('行为提示词'));
    final source = tester.getRect(find.text('全局'));
    final arrow = tester.getRect(find.byIcon(Icons.chevron_right));
    expect(source.center.dy, closeTo(title.center.dy, 1));
    expect(source.left, greaterThan(title.right));
    expect(source.right, lessThan(arrow.left));
    expect(
      arrow.right,
      closeTo(tester.getBottomRight(find.byType(AiSandboxField)).dx, 1),
    );
    final inputWidth = tester.getSize(find.byType(AiSandboxField)).width;
    expect(
      tester.getSize(find.widgetWithText(FilledButton, '开始测试')).width,
      closeTo(inputWidth, 1),
    );
    await tester.tap(find.text('行为提示词'));
    await settle(tester);
    final editor = tester.widget<TextField>(find.byType(TextField));
    expect(editor.style!.fontSize, 15);
    expect(editor.style!.height, 1.8);
    expect(editor.expands, isTrue);
    await tester.enterText(find.byType(TextField), '本次校对规则');
    await tester.tap(find.text('使用'));
    await settle(tester);
    expect(
      tester.getCenter(find.text('本次自定义')).dy,
      closeTo(tester.getCenter(find.text('行为提示词')).dy, 1),
    );
    expect(find.text('查看本次请求'), findsNothing);
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await settle(tester);
    expect(
      tester.getRect(find.byIcon(Icons.chevron_right)).right,
      closeTo(tester.getBottomRight(find.byType(AiSandboxField)).dx, 1),
    );
    expect(find.text('本次自定义'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

  testWidgets('custom behavior, restore and discarded drafts stay local', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('AI 测试台'), findsOneWidget);
    expect(find.textContaining('WebDAV'), findsNothing);
    expect(
      tester
          .widget<AiSandboxRestoreOption>(find.byType(AiSandboxRestoreOption))
          .value,
      isTrue,
    );
    await visible(tester, find.text('行为提示词'));
    await tester.tap(find.text('行为提示词'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), '本次校对规则');
    await tester.tap(find.text('使用'));
    await settle(tester);
    expect(find.text('本次自定义'), findsOneWidget);
    expect(settings.global.behaviorPrompt, '全局校对规则');
    await tester.tap(find.text('行为提示词'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('使用'));
    await settle(tester);
    expect(find.text('提示词不能为空'), findsOneWidget);
    await tester.tap(find.text('恢复全局'));
    await settle(tester);
    await tester.tap(find.byTooltip('返回'));
    await settle(tester);
    expect(find.text('本次自定义'), findsOneWidget);
    await tester.tap(find.text('行为提示词'));
    await settle(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '本次校对规则',
    );
    await tester.tap(find.text('恢复全局'));
    await tester.tap(find.text('使用'));
    await settle(tester);
    expect(find.text('全局'), findsOneWidget);
    await tester.tap(find.byType(AiSandboxRestoreOption));
    await settle(tester);
    expect(settings.global.restoreCensoredWords, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

  testWidgets(
    'result tabs, highlights and failure raw output work in each appearance',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final result = aiSandboxValidate(
        aiSandboxSample,
        aiSandboxExampleResponse,
      );
      for (final classic in [true, false]) {
        for (final dark in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                extensions: [
                  classic
                      ? const AppStyleTokens.classic()
                      : const AppStyleTokens.archive(),
                ],
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: AiSandboxResultView(
                    key: ValueKey('$classic-$dark'),
                    result: result,
                  ),
                ),
              ),
            ),
          );
          await settle(tester);
          expect(find.byType(Tab), findsNWidgets(2));
          expect(find.text('原始 JSON'), findsNothing);
          final preview = tester.widget<SelectableText>(
            find.byKey(const ValueKey('sandbox-preview')),
          );
          final highlight = preview.textSpan!.children!
              .whereType<TextSpan>()
              .firstWhere((span) => span.text == '已经');
          expect(
            highlight.style!.backgroundColor,
            dark ? const Color(0xFF52332D) : const Color(0xFFFFEBE4),
          );
          final tabs = tester.widget<TabBar>(find.byType(TabBar));
          expect(tabs.indicatorWeight, 2);
          expect(tabs.labelColor, isNot(tabs.unselectedLabelColor));
          await tester.tap(find.text('修改详情'));
          await settle(tester);
          expect(find.byKey(const ValueKey('sandbox-preview')), findsNothing);
          final original = tester.widget<SelectableText>(
            find.byWidgetPredicate(
              (widget) => widget is SelectableText && widget.data == '以经',
            ),
          );
          expect(original.style!.decoration, TextDecoration.lineThrough);
          expect(
            tester
                .widget<SelectableText>(
                  find.byWidgetPredicate(
                    (widget) => widget is SelectableText && widget.data == '已经',
                  ),
                )
                .style!
                .fontWeight,
            FontWeight.w500,
          );
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiSandboxResultView(
                result: aiSandboxValidate(aiSandboxSample, '{broken'),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('校验未通过'), findsOneWidget);
      expect(find.byType(Tab), findsNothing);
      final raw = tester.widget<SelectableText>(
        find.byKey(const ValueKey('sandbox-raw')),
      );
      expect(raw.data, '{broken');
      expect(raw.style!.fontFamily, 'monospace');
      expect(raw.style!.fontSize, 12);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets(
    'JSON route retains independent drafts, validation and deletion marker',
    (tester) async {
      await open(tester);
      await jsonPage(tester);
      await tester.enterText(find.byType(TextField).first, '唯一错字。');
      await tester.enterText(
        find.byType(TextField).last,
        '{"edits":[{"original":"错","replacement":"","category":"删除重复字","reason":"测试删除"}]}',
      );
      await visible(tester, find.text('校验并预览'));
      await tester.tap(find.text('校验并预览'));
      await settle(tester);
      expect(find.text('校验通过'), findsOneWidget);
      final preview = tester.widget<SelectableText>(
        find.byKey(const ValueKey('sandbox-preview')),
      );
      expect(
        preview.textSpan!.toPlainText(includeSemanticsLabels: false),
        '唯一│字。',
      );
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        aiSandboxSample,
      );
      await jsonPage(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '唯一错字。',
      );
      expect(find.text('校验通过'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).last,
        '{"edits":[{"original":"不存在","replacement":"改","category":"自定义类别","reason":"原因"}]}',
      );
      await visible(tester, find.text('校验并预览'));
      await tester.tap(find.text('校验并预览'));
      await settle(tester);
      expect(find.textContaining('ORIGINAL_NOT_FOUND'), findsOneWidget);
      expect(find.textContaining('第 1 条修改'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets(
    'actual SSE messages, frozen preview, usage and raw response transfer',
    (tester) async {
      final client = (await tester.runAsync(() async => _SseClient()))!;
      await open(tester, client: client);
      // Keep the Future in a record: returning it directly would await the run.
      late Future<void> done;
      final button = find.widgetWithText(FilledButton, '开始测试');
      await visible(tester, button);
      final callback =
          tester.widget<FilledButton>(button).onPressed!
              as Future<void> Function();
      await tester.runAsync(() async {
        done = callback();
        await client.received.future.timeout(const Duration(seconds: 5));
        client.delta('推理', reasoning: true);
      });
      await settle(tester);
      expect(find.textContaining('思考中'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await settle(tester);
      final startRect = tester.getRect(find.byType(FilledButton));
      final stopRect = tester.getRect(
        find.widgetWithText(OutlinedButton, '停止'),
      );
      expect(
        startRect.width,
        closeTo(tester.getSize(find.byType(AiSandboxField)).width, 1),
      );
      expect(stopRect.top, greaterThan(startRect.bottom));
      expect(tester.takeException(), isNull);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await settle(tester);
      final system =
          (client.body!['messages'] as List).first['content'] as String;
      expect(
        system,
        aiBuildSystemPrompt(
          behaviorPrompt: '全局校对规则',
          outputMode: AiOutputMode.jsonObject,
          restoreCensoredWords: true,
        ),
      );
      expect(
        (client.body!['messages'] as List).last['content'],
        aiSandboxSample,
      );
      expect(
        client.body!['response_format'],
        AiChatCompletionsClient.responseFormat(AiOutputMode.jsonObject),
      );
      await tester.runAsync(
        () => settings.saveGlobal(
          settings.global.copyWith(
            behaviorPrompt: '后来修改的全局规则',
            modelId: 'other-model',
          ),
        ),
      );
      await visible(tester, find.text('查看请求'));
      await tester.tap(find.text('查看请求'));
      await settle(tester);
      expect(
        tester
            .widget<AiSandboxRequestPage>(find.byType(AiSandboxRequestPage))
            .request
            .settings
            .modelId,
        'fixture-model',
      );
      expect(find.text(system), findsOneWidget);
      expect(client.aborted.isCompleted, isFalse);
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      const raw = ' { "edits" : [] } ';
      await tester.runAsync(() async {
        client.delta(raw);
        await client.finish();
        await done.timeout(const Duration(seconds: 5));
      });
      await settle(tester);
      await visible(tester, find.text('测试完成'));
      expect(find.text('0 处修改'), findsOneWidget);
      expect(find.text('150 tokens'), findsOneWidget);
      final result = tester
          .widget<AiSandboxResultView>(find.byType(AiSandboxResultView))
          .result!;
      expect(result.request!.settings.modelId, 'fixture-model');
      expect(result.request!.behaviorSource, '全局提示词');
      expect(find.text('上次结果'), findsOneWidget);
      expect(find.text('fixture-model · 全局提示词 · 去屏蔽词开启'), findsOneWidget);
      await visible(tester, find.text('查看请求'));
      await tester.tap(find.text('查看请求'));
      await settle(tester);
      expect(
        tester
            .widget<AiSandboxRequestPage>(find.byType(AiSandboxRequestPage))
            .request
            .settings
            .modelId,
        'other-model',
      );
      expect(find.textContaining('后来修改的全局规则'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      await visible(tester, find.text('查看本次请求'));
      await tester.tap(find.text('查看本次请求'));
      await settle(tester);
      expect(
        tester
            .widget<AiSandboxRequestPage>(find.byType(AiSandboxRequestPage))
            .request
            .settings
            .modelId,
        'fixture-model',
      );
      expect(find.text(system), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), '下一次的正文');
      await visible(tester, find.text('行为提示词'));
      await tester.tap(find.text('行为提示词'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), '下一次自定义规则');
      await tester.tap(find.text('使用'));
      await settle(tester);
      await tester.tap(find.byType(AiSandboxRestoreOption));
      await settle(tester);
      expect(
        tester
            .widget<AiSandboxResultView>(find.byType(AiSandboxResultView))
            .result,
        same(result),
      );
      expect(result.request!.source, aiSandboxSample);
      expect(result.request!.behavior, '全局校对规则');
      expect(result.request!.restore, isTrue);
      await visible(tester, find.text('查看请求'));
      await tester.tap(find.text('查看请求'));
      await settle(tester);
      expect(
        find.text(
          aiBuildSystemPrompt(
            behaviorPrompt: '下一次自定义规则',
            outputMode: AiOutputMode.jsonObject,
            restoreCensoredWords: false,
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('User'));
      await settle(tester);
      expect(find.text('下一次的正文'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      await visible(tester, find.text('查看本次请求'));
      await tester.tap(find.text('查看本次请求'));
      await settle(tester);
      expect(find.text(system), findsOneWidget);
      await tester.tap(find.text('User'));
      await settle(tester);
      expect(find.text(aiSandboxSample), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      await visible(tester, find.text('原始 JSON'));
      await tester.tap(find.text('原始 JSON'));
      await settle(tester);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const ValueKey('sandbox-raw')))
            .data,
        raw,
      );
      await tester.tap(find.text('用于 JSON 校验'));
      await settle(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        aiSandboxSample,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        raw,
      );
      expect(client.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets(
    'stop aborts the stream and preserves partial failed response without retry',
    (tester) async {
      final client = (await tester.runAsync(() async => _SseClient()))!;
      await open(tester, client: client);
      late Future<void> done;
      await visible(tester, find.widgetWithText(FilledButton, '开始测试'));
      final callback =
          tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, '开始测试'),
                  )
                  .onPressed!
              as Future<void> Function();
      await tester.runAsync(() async {
        done = callback();
        await client.received.future.timeout(const Duration(seconds: 5));
        client.delta('{"edits":');
      });
      await settle(tester);
      await tester.tap(find.text('停止'));
      await tester.runAsync(() async {
        await client.aborted.future.timeout(const Duration(seconds: 5));
        await done.timeout(const Duration(seconds: 5));
      });
      await settle(tester);
      expect(find.text('测试已停止'), findsOneWidget);
      expect(find.text('Token 用量未知'), findsOneWidget);
      expect(client.calls, 1);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const ValueKey('sandbox-raw')))
            .data,
        '{"edits":',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets('leaving console aborts; entering JSON tools does not', (
    tester,
  ) async {
    final client = (await tester.runAsync(() async => _SseClient()))!;
    await open(tester, client: client);
    late Future<void> done;
    await visible(tester, find.widgetWithText(FilledButton, '开始测试'));
    final callback =
        tester
                .widget<FilledButton>(find.widgetWithText(FilledButton, '开始测试'))
                .onPressed!
            as Future<void> Function();
    await tester.runAsync(() async {
      done = callback();
      await client.received.future.timeout(const Duration(seconds: 5));
    });
    await settle(tester);
    await jsonPage(tester);
    expect(client.aborted.isCompleted, isFalse);
    await tester.tap(find.byTooltip('返回'));
    await settle(tester);
    expect(client.aborted.isCompleted, isFalse);
    await tester.tap(find.byTooltip('返回'));
    await settle(tester);
    await tester.runAsync(() async {
      await client.aborted.future.timeout(const Duration(seconds: 5));
      await done.timeout(const Duration(seconds: 5));
    });
    expect(client.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

  testWidgets(
    'blocked test keeps configuration without claiming a sent request',
    (tester) async {
      final client = (await tester.runAsync(() async => _SseClient()))!;
      await tester.runAsync(
        () => settings.saveGlobal(settings.global.copyWith(enabled: false)),
      );
      await open(tester, client: client);
      await visible(tester, find.widgetWithText(FilledButton, '开始测试'));
      final callback =
          tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, '开始测试'),
                  )
                  .onPressed!
              as Future<void> Function();
      await tester.runAsync(
        () => callback().timeout(const Duration(seconds: 5)),
      );
      await settle(tester);
      final result = tester
          .widget<AiSandboxResultView>(find.byType(AiSandboxResultView))
          .result!;
      expect(result.requests, 0);
      expect(result.request!.settings.modelId, 'fixture-model');
      expect(client.calls, 0);
      expect(find.text('查看本次请求'), findsNothing);
      await visible(tester, find.text('查看请求'));
      await tester.tap(find.text('查看请求'));
      await settle(tester);
      expect(
        tester
            .widget<AiSandboxRequestPage>(find.byType(AiSandboxRequestPage))
            .request
            .settings
            .modelId,
        'fixture-model',
      );
      expect(find.text('当前配置预览'), findsNothing);
      expect(find.text('本次请求快照'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets(
    'budget confirmation sends exactly one manually approved request',
    (tester) async {
      final client = (await tester.runAsync(() async => _SseClient()))!;
      await tester.runAsync(
        () =>
            settings.saveGlobal(settings.global.copyWith(dailyRequestLimit: 0)),
      );
      final observer = (await tester.runAsync(() async => _DialogObserver()))!;
      await open(tester, client: client, observer: observer);
      await visible(tester, find.widgetWithText(FilledButton, '开始测试'));
      late Future<void> done;
      final callback =
          tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, '开始测试'),
                  )
                  .onPressed!
              as Future<void> Function();
      await tester.runAsync(() async {
        done = callback();
        await observer.shown.future.timeout(const Duration(seconds: 5));
      });
      await settle(tester);
      expect(find.text('本次请求将超出预算'), findsOneWidget);
      expect(client.calls, 0);
      expect(find.text('查看本次请求'), findsNothing);
      await tester.tap(find.text('仍然请求'));
      await tester.runAsync(() async {
        await client.received.future.timeout(const Duration(seconds: 5));
        client.delta('{"edits":[]}');
        await client.finish();
        await done.timeout(const Duration(seconds: 5));
      });
      await settle(tester);
      expect(find.text('测试完成'), findsOneWidget);
      expect(client.calls, 1);
      expect(settings.global.dailyRequestLimit, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets(
    'schema response carries descriptions and truncated raw output remains available',
    (tester) async {
      final client = (await tester.runAsync(() async => _SseClient()))!;
      await tester.runAsync(() async {
        final provider = settings
            .provider('fixture')!
            .copyWith(outputMode: AiOutputMode.jsonSchema);
        await settings.upsertProvider(provider);
        await settings.saveCapability(
          AiModelCapability(
            key: AiSettingsStore.capabilityKey(
              providerId: provider.id,
              baseUrl: provider.baseUrl,
              modelId: 'fixture-model',
              mode: AiOutputMode.jsonSchema,
            ),
            providerId: provider.id,
            endpoint: AiChatCompletionsClient.endpoint(
              provider.baseUrl,
            ).toString(),
            apiFamily: 'chat.completions',
            modelId: 'fixture-model',
            outputMode: AiOutputMode.jsonSchema,
            schemaStrict: true,
            schemaProjectionHash: aiSchemaProjectionHash(),
            verifiedAt: DateTime.now(),
            ok: true,
          ),
        );
      });
      await open(tester, client: client);
      await visible(tester, find.widgetWithText(FilledButton, '开始测试'));
      late Future<void> done;
      final callback =
          tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, '开始测试'),
                  )
                  .onPressed!
              as Future<void> Function();
      await tester.runAsync(() async {
        done = callback();
        await client.received.future.timeout(const Duration(seconds: 5));
        client.delta('{"edits":[');
        await client.finish(reason: 'length');
        await done.timeout(const Duration(seconds: 5));
      });
      await settle(tester);
      final format = client.body!['response_format'] as Map;
      expect(
        format,
        AiChatCompletionsClient.responseFormat(AiOutputMode.jsonSchema),
      );
      expect(
        ((format['json_schema'] as Map)['schema'] as Map)['description'],
        isNotEmpty,
      );
      final system =
          (client.body!['messages'] as List).first['content'] as String;
      expect(system, isNot(contains(kAiJsonObjectProtocol.trim())));
      expect(find.text('测试失败'), findsOneWidget);
      expect(find.textContaining('FINISH_REASON_LENGTH'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const ValueKey('sandbox-raw')))
            .data,
        '{"edits":[',
      );
      expect(find.text('150 tokens'), findsOneWidget);
      expect(client.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      await tester.runAsync(
        () => settings.upsertProvider(
          settings
              .provider('fixture')!
              .copyWith(outputMode: AiOutputMode.jsonObject),
        ),
      );
    },
  );

  testWidgets(
    '320px, 2x text, dark/classic/archive keep drafts and avoid overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final style = ValueNotifier(false);
      addTearDown(style.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: style,
          builder: (context, archive, _) => MaterialApp(
            theme: ThemeData(
              brightness: archive ? Brightness.dark : Brightness.light,
              extensions: [
                archive
                    ? const AppStyleTokens.archive()
                    : const AppStyleTokens.classic(),
              ],
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: const DeveloperToolsPage(),
          ),
        ),
      );
      await settle(tester);
      await tester.enterText(find.byType(TextField), '保留的正文草稿');
      style.value = true;
      await settle(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留的正文草稿',
      );
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(375, 900);
      await settle(tester);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(1024, 768);
      await settle(tester);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(320, 900);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);
      await settle(tester);
      await visible(tester, find.text('行为提示词'));
      await tester.tap(find.text('行为提示词'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('使用'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );
}
