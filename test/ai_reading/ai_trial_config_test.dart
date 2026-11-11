import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/services/ai_reading/ai_client.dart';
import 'package:fqapp/services/ai_reading/ai_coordinator.dart';
import 'package:fqapp/services/ai_reading/ai_credentials.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/ai_reading/ai_prompt.dart';
import 'package:fqapp/services/ai_reading/ai_settings.dart';
import 'package:fqapp/services/ai_reading/ai_store.dart';
import 'package:fqapp/services/ai_reading/ai_trials.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';

import '../support/secure_key_storage_mock.dart';

const _behavior = '请按上下文润色。';
final _chapters = [
  AiTrialChapter(
    chapterId: 'one',
    title: '',
    content: ChapterContent(blocks: [const ChapterParagraph('第一处正文。')]),
  ),
  AiTrialChapter(
    chapterId: 'two',
    title: '',
    content: ChapterContent(blocks: [const ChapterParagraph('第二处正文。')]),
  ),
];

http.Response _emptyEdits() => http.Response(
  'data: ${jsonEncode({
    'choices': [
      {
        'finish_reason': 'stop',
        'delta': {'content': '{"edits":[]}'},
      },
    ],
  })}\n\ndata: [DONE]\n\n',
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

bool _hasRecovery(http.Request request) {
  final body = jsonDecode(request.body) as Map;
  final system = (body['messages'] as List).first['content'] as String;
  return system.contains(kAiRestoreCensoredWordsPrompt.trim());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = AiSettingsStore.instance;
  final store = AiStore.instance;
  late Directory directory;

  setUpAll(() async {
    mockSecureKeyStorage();
    directory = await Directory.systemTemp.createTemp('ai-trial-config-');
    Hive.init(directory.path);
    await settings.init();
    await store.init();
    expect(settings.isAvailable, isTrue, reason: settings.status);
    expect(store.isAvailable, isTrue, reason: store.status);
    await settings.upsertProvider(
      AiProviderProfile(
        id: 'fixture',
        label: 'Fixture',
        baseUrl: 'https://example.invalid/v1',
        credentialRef: 'fixture-key',
        outputMode: AiOutputMode.jsonObject,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    await AiCredentialStore.instance.write('fixture-key', 'test-key');
    await settings.saveDevice(const AiDeviceSettings(cloudConsent: true));
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await settings.saveGlobal(
      const AiGlobalSettings(
        enabled: true,
        providerId: 'fixture',
        modelId: 'fixture-model',
        behaviorPrompt: _behavior,
      ),
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  tearDownAll(() async {
    await Hive.close().timeout(const Duration(seconds: 5));
    await directory.delete(recursive: true);
  });

  test(
    'trial chapters retain the initial feature snapshot; next trial changes',
    () async {
      final recoverySent = <bool>[];
      final transport = MockClient((request) async {
        recoverySent.add(_hasRecovery(request));
        if (recoverySent.length == 1) {
          await settings.saveGlobal(
            settings.global.copyWith(restoreCensoredWords: true),
          );
        }
        return _emptyEdits();
      });
      addTearDown(transport.close);
      final service = AiTrialService(
        coordinator: AiCoordinator(
          client: AiChatCompletionsClient(client: transport),
        ),
      );
      final first = await service.run(
        bookId: 'trial-book',
        candidatePrompt: _behavior,
        chapters: _chapters,
        feedbackCases: const [],
      );
      final second = await service.run(
        bookId: 'trial-book',
        candidatePrompt: settings.resolvedPrompt('trial-book').text,
        chapters: _chapters,
        feedbackCases: const [],
      );
      expect(first.state, 'completed');
      expect(second.state, 'completed');
      expect(recoverySent, [false, false, true, true]);
      expect(second.configSnapshotHash, isNot(first.configSnapshotHash));
      // The candidate identity remains the editable behavior, independent of
      // program-owned options captured in configSnapshotHash.
      expect(second.candidateHash, first.candidateHash);
      expect(settings.resolvedPrompt('trial-book').text, _behavior);

      final runs = {for (final run in await store.runs()) run.runId: run};
      Future<Set<String>> configs(AiTrialRecord trial) async => {
        for (final result in await store.trialResults(trial.trialId))
          runs[result.runId]!.configSnapshotHash,
      };
      final firstConfigs = await configs(first);
      final secondConfigs = await configs(second);
      expect(firstConfigs, hasLength(1));
      expect(secondConfigs, hasLength(1));
      expect(secondConfigs.single, isNot(firstConfigs.single));
    },
  );

  test(
    'formal and sandbox run hashes describe the prompt and option sent',
    () async {
      final recoverySent = <bool>[];
      final transport = MockClient((request) async {
        recoverySent.add(_hasRecovery(request));
        return _emptyEdits();
      });
      addTearDown(transport.close);
      final coordinator = AiCoordinator(
        client: AiChatCompletionsClient(client: transport),
      );
      Future<AiTaskResult> run({
        bool? restore,
        String? override,
        void Function(AiRunState)? onState,
      }) => coordinator.runFormal(
        bookId: 'formal-book',
        chapterId: 'sample',
        chapterTitle: '',
        content: _chapters.first.content,
        forceRefresh: true,
        kind: override == null ? AiRunKind.formalFirst : AiRunKind.trial,
        behaviorPromptOverride: override,
        restoreCensoredWords: restore,
        onState: onState,
      );

      late Future<void> changed;
      final initial = await run(
        onState: (state) {
          if (state == AiRunState.running) {
            changed = settings.saveGlobal(
              settings.global.copyWith(restoreCensoredWords: true),
            );
          }
        },
      );
      await changed;
      final explicitOff = await run(restore: false);
      final enabled = await run();
      final sandboxOff = await run(restore: false, override: _behavior);
      final otherPrompt = await run(restore: false, override: '另一份候选提示词');
      final results = [initial, explicitOff, enabled, sandboxOff, otherPrompt];
      expect(results.every((result) => result.ok), isTrue);
      expect(recoverySent, [false, false, true, false, false]);
      final runs = {for (final run in await store.runs()) run.runId: run};
      final hashes = results
          .map((result) => runs[result.runId]!.configSnapshotHash)
          .toList();
      expect(hashes[1], hashes[0]);
      expect(hashes[2], isNot(hashes[0]));
      expect(hashes[3], hashes[0]);
      expect(hashes[4], isNot(hashes[3]));
    },
  );
}
