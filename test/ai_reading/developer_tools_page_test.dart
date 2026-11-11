import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/pages/ai_reading/settings/developer_tools_page.dart';
import 'package:fqapp/pages/ai_reading/settings/ai_sandbox_widgets.dart';
import 'package:fqapp/services/ai_reading/ai_client.dart';
import 'package:fqapp/services/ai_reading/ai_controller.dart';
import 'package:fqapp/services/ai_reading/ai_coordinator.dart';
import 'package:fqapp/services/ai_reading/ai_credentials.dart';
import 'package:fqapp/services/ai_reading/ai_prompt.dart';
import 'package:fqapp/services/ai_reading/ai_settings.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/app_style_tokens.dart';

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
    FlutterSecureStorage.setMockInitialValues({});
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

  testWidgets('custom behavior, restore and discarded drafts stay local', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('AI 测试台'), findsOneWidget);
    expect(find.textContaining('WebDAV'), findsNothing);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
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
    await tester.tap(find.byType(SwitchListTile));
    await settle(tester);
    expect(settings.global.restoreCensoredWords, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

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
      expect(find.text('本次请求快照'), findsOneWidget);
      expect(find.text('Fixture / fixture-model'), findsOneWidget);
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
