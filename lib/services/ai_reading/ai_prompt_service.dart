import 'ai_budget.dart';
import 'ai_client.dart';
import 'ai_credentials.dart';
import 'ai_models.dart';
import 'ai_prompt.dart';
import 'ai_request_foreground.dart';
import 'ai_settings.dart';
import 'ai_store.dart';

class AiPromptService {
  AiPromptService({
    AiStore? store,
    AiSettingsStore? settings,
    AiCredentialStore? credentials,
    AiChatCompletionsClient? client,
  }) : _store = store ?? AiStore.instance,
       _settings = settings ?? AiSettingsStore.instance,
       _credentials = credentials ?? AiCredentialStore.instance,
       _client = client ?? AiChatCompletionsClient();

  static final instance = AiPromptService();
  final AiStore _store;
  final AiSettingsStore _settings;
  final AiCredentialStore _credentials;
  final AiChatCompletionsClient _client;

  Future<List<AiPromptRecord>> history(String bookId) async {
    final records = (await _store.prompts())
        .where((record) => record.bookId == bookId)
        .toList(growable: false);
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return records;
  }

  Future<String> previewSystemPrompt(String bookId) async {
    final effective = _settings.resolve(bookId);
    final provider = _settings.provider(effective.providerId);
    return aiBuildSystemPrompt(
      behaviorPrompt: _settings.resolvedPrompt(bookId).text,
      outputMode: provider?.outputMode ?? AiOutputMode.jsonObject,
    );
  }

  Future<void> undoLastAdopt(String bookId) async {
    final records = await history(bookId);
    final active = records.where((record) => record.active).toList();
    if (active.isEmpty) {
      await _settings.clearBookOverride(bookId, 'behaviorPrompt');
      return;
    }
    final latest = active.first;
    final previous = records
        .where(
          (record) =>
              record.promptId != latest.promptId &&
              record.active &&
              record.createdAt.isBefore(latest.createdAt),
        )
        .toList();
    await _store.putPrompt(latest.copyWith(active: false));
    if (previous.isEmpty) {
      await _settings.clearBookOverride(bookId, 'behaviorPrompt');
      return;
    }
    await _settings.setBookOverride(
      bookId,
      'behaviorPrompt',
      previous.first.text,
    );
  }

  Future<AiPromptCandidate> createDraft({
    required String bookId,
    required String body,
    Map<String, int> feedbackRevisions = const {},
  }) async {
    final now = DateTime.now();
    final candidate = AiPromptCandidate(
      candidateId: 'cand_${now.microsecondsSinceEpoch.toRadixString(36)}',
      bookId: bookId,
      basePromptId: _settings.resolvedPrompt(bookId).promptId,
      body: body,
      draftState: 'draft',
      feedbackCaseRevisions: feedbackRevisions,
      createdAt: now,
    );
    await _store.putCandidate(candidate);
    return candidate;
  }

  Future<AiPromptCandidate> createFromFeedback({
    required String bookId,
    required List<AiFeedbackCase> feedback,
    String? instruction,
  }) async {
    final effective = _settings.resolve(bookId);
    if (!effective.enabled) {
      throw const AiNetworkException('AI_DISABLED', 'AI 阅读优化未开启');
    }
    if (_settings.device.deviceDisabled) {
      throw const AiNetworkException('DEVICE_DISABLED', '本机已停用 AI 请求');
    }
    if (!_settings.device.cloudConsent) {
      throw const AiNetworkException('NO_CONSENT', '还没有同意云端正文传输');
    }
    final budget = await AiBudgetService.instance.check(
      bookId: bookId,
      automatic: false,
    );
    if (budget.needsConfirmation) {
      throw AiNetworkException('BUDGET_EXCEEDED', budget.reason ?? '本次请求将超出预算');
    }
    if (!budget.allowed) {
      throw AiNetworkException(
        budget.code ?? 'BUDGET_EXCEEDED',
        budget.reason ?? '预算已用完',
      );
    }
    final provider = _settings.provider(effective.providerId);
    final model = effective.modelId;
    if (provider == null || model == null) {
      throw const AiNetworkException('PROVIDER_MISSING', '还没有选择提供商和模型');
    }
    final key = await _credentials.read(provider.credentialRef);
    if (key == null) {
      throw const AiNetworkException('MISSING_KEY', '还没有填写 API Key');
    }
    final foreground = await AiRequestForeground.acquire();
    try {
      final started = DateTime.now();
      final requestId =
          'req_prompt_${started.microsecondsSinceEpoch.toRadixString(36)}';
      final runId = 'run_${started.microsecondsSinceEpoch.toRadixString(36)}';
      final reserved = await AiBudgetService.instance.reserve(
        bookId: bookId,
        automatic: false,
        countTask: true,
        requestId: requestId,
        runId: runId,
      );
      final reservation = reserved.reservation;
      if (reservation == null) {
        throw AiNetworkException(
          reserved.code ?? 'BUDGET_EXCEEDED',
          reserved.reason ?? '预算已用完',
        );
      }
      final samples = feedback
          .take(30)
          .map((f) {
            return '类型：${f.kind.label}\n'
                '原文：${f.anchor.sourceText}\n'
                '期望：${f.assertion.expectedText ?? f.assertion.type}\n'
                '说明：${f.comment}';
          })
          .join('\n\n');
      final rateProfile = _settings.rateFor(provider.id, model);
      final rate = rateProfile?.snapshot();
      final runRecord = AiRunRecord(
        runId: runId,
        kind: AiRunKind.promptOptimize,
        bookId: bookId,
        chapterId: '',
        canonicalHash: '',
        configSnapshotHash: _hash(_settings.resolvedPrompt(bookId).text),
        state: AiRunState.running,
        attemptCount: 0,
        formalEligible: false,
        startedAt: started,
      );
      await _store.putRun(runRecord);
      // The run write is asynchronous. Re-check consent after it, immediately
      // before the request body is sent; the budget queue may have waited too.
      final blocked = _liveGate(bookId);
      if (blocked != null) {
        await AiBudgetService.instance.release(reservation);
        await _store.putRun(
          runRecord.copyWith(
            state: AiRunState.cancelled,
            finishedAt: DateTime.now(),
            errorCodes: [blocked.code],
            detail: blocked.message,
          ),
        );
        throw blocked;
      }
      AiProviderResponse response;
      try {
        response = await _client.complete(
          profile: provider,
          apiKey: key,
          model: model,
          messages: [
            {
              'role': 'system',
              'content':
                  '你是中文小说校对提示词编辑。只输出修订后的完整提示词，不要解释，不要 Markdown。'
                  '保留原有保守校对原则，不得放宽为文学润色。',
            },
            {
              'role': 'user',
              'content':
                  '当前提示词：\n${_settings.resolvedPrompt(bookId).text}\n\n'
                  '用户反馈样本：\n$samples\n\n'
                  '${instruction ?? '请根据这些反馈收紧提示词，减少误改，并补充容易漏掉的同类错误。'}',
            },
          ],
          outputMode: AiOutputMode.jsonObject,
          timeout: Duration(seconds: effective.requestTimeoutSeconds),
          jsonResponse: false,
          abortTrigger: foreground.abortTrigger,
        );
      } catch (error) {
        final finished = DateTime.now();
        final usage = error is AiNetworkException
            ? (error.usage ?? const AiUsage())
            : const AiUsage();
        final request = AiRequestRecord(
          requestId: requestId,
          runId: runId,
          attemptNo: 1,
          providerId: provider.id,
          endpoint: AiChatCompletionsClient.endpoint(
            provider.baseUrl,
          ).toString(),
          model: model,
          mode: AiOutputMode.jsonObject,
          usage: usage,
          startedAt: started,
          latencyMs: finished.difference(started).inMilliseconds,
          errorCode: error is AiNetworkException
              ? error.code
              : 'PROMPT_OPTIMIZE_FAILED',
          rateSnapshot: rate,
          costMicros: aiEstimateCostMicros(usage, rate),
          currency: rate?.currency ?? effective.global.costCurrency,
          reason: 'prompt_optimize',
        );
        await _store.putRequest(request);
        await AiBudgetService.instance.settle(
          reservation: reservation,
          request: request,
        );
        await _store.putRun(
          AiRunRecord(
            runId: runId,
            kind: AiRunKind.promptOptimize,
            bookId: bookId,
            chapterId: '',
            canonicalHash: '',
            configSnapshotHash: _hash(_settings.resolvedPrompt(bookId).text),
            state: AiRunState.failed,
            attemptCount: 1,
            formalEligible: false,
            startedAt: started,
          ),
        );
        rethrow;
      }
      final finished = DateTime.now();
      final request = AiRequestRecord(
        requestId: requestId,
        runId: runId,
        attemptNo: 1,
        providerId: provider.id,
        endpoint: AiChatCompletionsClient.endpoint(provider.baseUrl).toString(),
        model: model,
        mode: AiOutputMode.jsonObject,
        usage: response.usage,
        startedAt: started,
        latencyMs: finished.difference(started).inMilliseconds,
        rateSnapshot: rate,
        costMicros: aiEstimateCostMicros(response.usage, rate),
        currency: rate?.currency ?? effective.global.costCurrency,
        reason: 'prompt_optimize',
      );
      await _store.putRequest(request);
      await AiBudgetService.instance.settle(
        reservation: reservation,
        request: request,
      );
      await _store.putRun(
        AiRunRecord(
          runId: runId,
          kind: AiRunKind.promptOptimize,
          bookId: bookId,
          chapterId: '',
          canonicalHash: '',
          configSnapshotHash: _hash(_settings.resolvedPrompt(bookId).text),
          state: AiRunState.success,
          attemptCount: 1,
          formalEligible: false,
          startedAt: started,
        ),
      );
      final body = response.content.trim();
      if (body.isEmpty) {
        throw const AiNetworkException('RESPONSE_EMPTY', '候选提示词为空');
      }
      final candidate = await createDraft(
        bookId: bookId,
        body: body,
        feedbackRevisions: {
          for (final f in feedback) f.feedbackId: f.caseRevision,
        },
      );
      return candidate;
    } finally {
      await foreground.release();
    }
  }

  Future<void> adopt(AiPromptCandidate candidate) async {
    final now = DateTime.now();
    final records = await history(candidate.bookId);
    final previous = records.where((record) => record.active).toList();
    for (final record in previous) {
      await _store.putPrompt(record.copyWith(active: false));
    }
    await _settings.setBookOverride(
      candidate.bookId,
      'behaviorPrompt',
      candidate.body,
    );
    await _store.putPrompt(
      AiPromptRecord(
        promptId: 'prompt_${now.microsecondsSinceEpoch.toRadixString(36)}',
        bookId: candidate.bookId,
        revision: (previous.isEmpty ? 0 : previous.first.revision) + 1,
        source: 'adopted',
        text: candidate.body,
        hash: _hash(candidate.body),
        parentId: previous.isEmpty
            ? candidate.basePromptId
            : previous.first.promptId,
        createdAt: now,
      ),
    );
    await _store.putCandidate(
      AiPromptCandidate(
        candidateId: candidate.candidateId,
        bookId: candidate.bookId,
        basePromptId: candidate.basePromptId,
        body: candidate.body,
        draftState: 'adopted',
        feedbackCaseRevisions: candidate.feedbackCaseRevisions,
        createdAt: candidate.createdAt,
        adoptedAt: now,
      ),
    );
  }

  Future<void> restoreInherit(String bookId) =>
      _settings.clearBookOverride(bookId, 'behaviorPrompt');

  Future<void> restoreFactory(String bookId) => _settings.setBookOverride(
    bookId,
    'behaviorPrompt',
    kAiDefaultBehaviorPrompt,
  );

  Future<void> setGlobalPrompt(String? text) =>
      _settings.saveGlobal(_settings.global.copyWith(behaviorPrompt: text));

  AiNetworkException? _liveGate(String bookId) {
    final live = _settings.resolve(bookId);
    if (!live.enabled) {
      return const AiNetworkException('AI_DISABLED', 'AI 阅读优化未开启');
    }
    if (_settings.device.deviceDisabled) {
      return const AiNetworkException('DEVICE_DISABLED', '本机已停用 AI 请求');
    }
    if (!_settings.device.cloudConsent) {
      return const AiNetworkException('NO_CONSENT', '还没有同意云端正文传输');
    }
    return null;
  }

  static String _hash(String value) {
    var hash = 2166136261;
    for (final code in value.codeUnits) {
      hash ^= code;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }
}
