import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../chapter_text_formatter.dart';
import 'ai_budget.dart';
import 'ai_chapter_snapshot.dart';
import 'ai_client.dart';
import 'ai_credentials.dart';
import 'ai_models.dart';
import 'ai_prompt.dart';
import 'ai_protocol.dart';
import 'ai_settings.dart';
import 'ai_store.dart';

class AiTaskResult {
  const AiTaskResult({
    required this.ok,
    required this.runId,
    required this.snapshot,
    this.formal,
    this.validation,
    this.error,
    this.errorCodes = const [],
    this.requestCount = 0,
    this.needsBudgetConfirmation = false,
    this.budgetMessage,
  });

  final bool ok;
  final String runId;
  final AiChapterSnapshot snapshot;
  final AiFormalCacheEntry? formal;
  final AiValidationResult? validation;
  final String? error;
  final List<String> errorCodes;
  final int requestCount;
  final bool needsBudgetConfirmation;
  final String? budgetMessage;
}

class AiCoordinator {
  AiCoordinator({
    AiStore? store,
    AiSettingsStore? settings,
    AiBudgetService? budget,
    AiCredentialStore? credentials,
    AiChatCompletionsClient? client,
    AiValidator? validator,
  }) : _store = store ?? AiStore.instance,
       _settings = settings ?? AiSettingsStore.instance,
       _budget = budget ?? AiBudgetService.instance,
       _credentials = credentials ?? AiCredentialStore.instance,
       _client = client ?? AiChatCompletionsClient(),
       _validator = validator ?? const AiValidator();

  static final instance = AiCoordinator();
  final AiStore _store;
  final AiSettingsStore _settings;
  final AiBudgetService _budget;
  final AiCredentialStore _credentials;
  final AiChatCompletionsClient _client;
  final AiValidator _validator;

  final _generations = <String, int>{};

  String _generationKey(String bookId, String hash) => '$bookId\u0000$hash';

  Future<AiTaskResult> runFormal({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required ChapterContent content,
    AiRunKind kind = AiRunKind.formalFirst,
    bool forceRefresh = false,
    bool confirmedOverBudget = false,
    bool automatic = false,
    String? behaviorPromptOverride,
    void Function(AiRunState state)? onState,
    void Function(AiStreamProgress progress)? onProgress,
    void Function(String message)? onNotice,
  }) async {
    final snapshot = AiChapterSnapshotBuilder.fromContent(
      content,
      chapterTitle,
    );
    final effective = _settings.resolve(bookId);
    final key = _generationKey(bookId, snapshot.canonicalHash);
    final bypassFormalCache =
        kind == AiRunKind.trial || kind == AiRunKind.promptOptimize;
    AiFormalCacheEntry? cachedFormal;
    debugPrint(
      '[AI] run start kind=${kind.name} book=$bookId chapter=$chapterId '
      'hash=${snapshot.canonicalHash} paragraphs=${snapshot.paragraphs.length}',
    );
    if (!bypassFormalCache) {
      cachedFormal = await _store.formal(bookId, snapshot.canonicalHash);
      if (cachedFormal != null && !forceRefresh) {
        return AiTaskResult(
          ok: true,
          runId: cachedFormal.activeRunId,
          snapshot: snapshot,
          formal: cachedFormal,
        );
      }
    }
    final gate = await _preflight(
      bookId: bookId,
      effective: effective,
      automatic: automatic,
      confirmedOverBudget: confirmedOverBudget,
      kind: kind,
    );
    if (gate != null) {
      debugPrint('[AI] preflight blocked ${gate.code}: ${gate.message}');
      return AiTaskResult(
        ok: false,
        runId: '',
        snapshot: snapshot,
        error: gate.message,
        errorCodes: [gate.code],
        needsBudgetConfirmation: gate.needsBudgetConfirmation,
        budgetMessage: gate.needsBudgetConfirmation ? gate.message : null,
      );
    }

    final provider = _settings.provider(effective.providerId);
    final model = effective.modelId;
    if (provider == null || model == null || model.trim().isEmpty) {
      debugPrint(
        '[AI] provider missing provider=${effective.providerId} model=$model',
      );
      return AiTaskResult(
        ok: false,
        runId: '',
        snapshot: snapshot,
        error: '还没有选择可用的提供商和模型',
        errorCodes: const ['PROVIDER_MISSING'],
      );
    }
    final apiKey = await _credentials.read(provider.credentialRef);
    if (apiKey == null) {
      debugPrint('[AI] missing api key ref=${provider.credentialRef}');
      return AiTaskResult(
        ok: false,
        runId: '',
        snapshot: snapshot,
        error: '还没有填写 API Key',
        errorCodes: const ['MISSING_KEY'],
      );
    }
    final outputMode = provider.outputMode;
    if (outputMode == AiOutputMode.jsonSchema) {
      final capability = _settings.capabilityFor(
        providerId: provider.id,
        modelId: model,
        mode: outputMode,
        baseUrl: provider.baseUrl,
      );
      if (capability == null || !capability.ok) {
        return AiTaskResult(
          ok: false,
          runId: '',
          snapshot: snapshot,
          error: '当前端点/模型还没有通过 JSON Schema 能力测试，请先在提供商里测试连接',
          errorCodes: const ['SCHEMA_UNVERIFIED'],
        );
      }
    }

    final inMemoryGeneration = _generations[key] ?? 0;
    final storedGeneration = cachedFormal?.generation ?? 0;
    final previous = inMemoryGeneration > storedGeneration
        ? inMemoryGeneration
        : storedGeneration;
    final generation = forceRefresh ? previous + 1 : previous;
    if (forceRefresh) _generations[key] = generation;
    final runId = _newId('run');
    final configHash = _configHash(effective, provider, model);
    final run = AiRunRecord(
      runId: runId,
      kind: kind,
      bookId: bookId,
      chapterId: chapterId,
      canonicalHash: snapshot.canonicalHash,
      configSnapshotHash: configHash,
      state: AiRunState.running,
      attemptCount: 0,
      formalEligible:
          kind != AiRunKind.trial && kind != AiRunKind.promptOptimize,
      startedAt: DateTime.now(),
    );
    await _store.putRun(run);
    onState?.call(AiRunState.running);

    final prompt = behaviorPromptOverride == null
        ? _settings.resolvedPrompt(bookId)
        : AiResolvedPrompt(
            text: behaviorPromptOverride,
            hash: _sha(behaviorPromptOverride),
            source: 'trial',
            promptId: 'trial_${_sha(behaviorPromptOverride)}',
          );
    final systemPrompt = aiBuildSystemPrompt(
      behaviorPrompt: prompt.text,
      outputMode: outputMode,
    );
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': snapshot.requestText},
    ];
    final timeout = Duration(seconds: effective.requestTimeoutSeconds);
    var requestCount = 0;
    var lastValidation = AiValidationResult.failure(const []);
    var contentRepairs = 0;
    var transportRetries = 0;
    var thinkingFallback = false;
    var requestProfile = provider;

    while (true) {
      requestCount++;
      final attemptNo = requestCount;
      final started = DateTime.now();
      AiProviderResponse? response;
      AiNetworkException? networkError;
      try {
        response = await _client.complete(
          profile: requestProfile,
          apiKey: apiKey,
          model: model,
          systemPrompt: messages.first['content']!,
          userText: messages.last['content']!,
          outputMode: outputMode,
          timeout: timeout,
          stream: true,
          attempt: attemptNo,
          onProgress: onProgress,
        );
      } on AiNetworkException catch (error) {
        networkError = error;
      }
      final latency = DateTime.now().difference(started);
      final usage = response?.usage ?? const AiUsage();
      final rateProfile = _settings.rateFor(provider.id, model);
      final rate = rateProfile?.snapshot();
      final requestRecord = AiRequestRecord(
        requestId: _newId('req'),
        runId: runId,
        attemptNo: attemptNo,
        providerId: provider.id,
        endpoint: AiChatCompletionsClient.endpoint(provider.baseUrl).toString(),
        model: model,
        mode: outputMode,
        usage: usage,
        startedAt: started,
        latencyMs: latency.inMilliseconds,
        errorCode: networkError?.code,
        rateSnapshot: rate,
        costMicros: aiEstimateCostMicros(usage, rate),
        currency: rate?.currency ?? effective.global.costCurrency,
        reason: thinkingFallback
            ? 'thinking_fallback'
            : contentRepairs > 0
            ? 'content_repair'
            : 'first',
      );
      await _store.putRequest(requestRecord);
      await _budget.recordRequest(
        bookId: bookId,
        request: requestRecord,
        countTask: attemptNo == 1,
      );

      if (networkError != null) {
        final truncatedThinking =
            networkError.code == 'FINISH_REASON_LENGTH' ||
            networkError.code == 'RESPONSE_EMPTY';
        final reasoningBurned =
            (networkError.usage?.reasoningTokens ?? 0) > 0 &&
            (networkError.usage?.completionTokens ?? 0) > 0;
        if (!thinkingFallback &&
            requestProfile.reasoningEffort != AiReasoningEffort.off &&
            truncatedThinking &&
            reasoningBurned) {
          thinkingFallback = true;
          requestProfile = provider.copyWith(
            reasoningEffort: AiReasoningEffort.off,
          );
          onNotice?.call('本次校对失败：${networkError.message}；已切换为关闭思考重试');
          debugPrint(
            '[AI] thinking exhausted output; retrying with thinking disabled',
          );
          continue;
        }
        if (networkError.retryable &&
            networkError.statusCode != null &&
            transportRetries < effective.transportRetryLimit) {
          transportRetries++;
          final wait = networkError.retryAfter ?? const Duration(seconds: 1);
          await Future<void>.delayed(wait);
          continue;
        }
        debugPrint(
          '[AI] network failed ${networkError.code}: ${networkError.message}',
        );
        await _store.putRun(
          run.copyWith(
            state: AiRunState.failed,
            attemptCount: requestCount,
            finishedAt: DateTime.now(),
            errorCodes: [networkError.code],
            detail: networkError.message,
          ),
        );
        onState?.call(AiRunState.failed);
        return AiTaskResult(
          ok: false,
          runId: runId,
          snapshot: snapshot,
          error: networkError.message,
          errorCodes: [networkError.code],
          requestCount: requestCount,
        );
      }

      final text = response!.content;
      if (text.length > 128 * 1024) {
        await _store.putRun(
          run.copyWith(
            state: AiRunState.failed,
            attemptCount: requestCount,
            finishedAt: DateTime.now(),
            errorCodes: const ['RETRY_CONTEXT_EXCEEDED'],
            detail: '模型响应过大',
          ),
        );
        onState?.call(AiRunState.failed);
        return AiTaskResult(
          ok: false,
          runId: runId,
          snapshot: snapshot,
          error: '模型响应过大，已停止纠错',
          errorCodes: const ['RETRY_CONTEXT_EXCEEDED'],
          requestCount: requestCount,
        );
      }
      lastValidation = _validator.validateContent(text, snapshot);
      if (lastValidation.valid) {
        if (kind == AiRunKind.trial || kind == AiRunKind.promptOptimize) {
          await _store.putRun(
            run.copyWith(
              state: AiRunState.success,
              attemptCount: requestCount,
              finishedAt: DateTime.now(),
            ),
          );
          onState?.call(AiRunState.success);
          return AiTaskResult(
            ok: true,
            runId: runId,
            snapshot: snapshot,
            validation: lastValidation,
            requestCount: requestCount,
          );
        }
        if ((_generations[key] ?? 0) != generation) {
          await _store.putRun(
            run.copyWith(
              state: AiRunState.cancelled,
              attemptCount: requestCount,
              finishedAt: DateTime.now(),
              errorCodes: const ['STALE_GENERATION'],
            ),
          );
          onState?.call(AiRunState.cancelled);
          return AiTaskResult(
            ok: false,
            runId: runId,
            snapshot: snapshot,
            error: '这次结果已被更新的刷新取代',
            errorCodes: const ['STALE_GENERATION'],
            requestCount: requestCount,
          );
        }
        final entry = _formalEntry(
          bookId: bookId,
          snapshot: snapshot,
          runId: runId,
          edits: lastValidation.edits,
          generation: generation,
          model: model,
          promptHash: prompt.hash,
        );
        try {
          final committed = await _store.putFormal(entry);
          if (!committed) {
            final current = await _store.formal(bookId, snapshot.canonicalHash);
            await _store.putRun(
              run.copyWith(
                state: AiRunState.cancelled,
                attemptCount: requestCount,
                finishedAt: DateTime.now(),
                errorCodes: const ['STALE_GENERATION'],
              ),
            );
            onState?.call(AiRunState.cancelled);
            return AiTaskResult(
              ok: current != null,
              runId: runId,
              snapshot: snapshot,
              formal: current,
              error: current == null ? '这次结果已被更新的刷新取代' : null,
              errorCodes: const ['STALE_GENERATION'],
              requestCount: requestCount,
            );
          }
        } catch (error) {
          await _store.putRun(
            run.copyWith(
              state: AiRunState.storageFailed,
              attemptCount: requestCount,
              finishedAt: DateTime.now(),
              errorCodes: const ['STORAGE_FAILED'],
              detail: '$error',
            ),
          );
          onState?.call(AiRunState.storageFailed);
          return AiTaskResult(
            ok: false,
            runId: runId,
            snapshot: snapshot,
            error: '校对结果写入失败，已保留旧缓存',
            errorCodes: const ['STORAGE_FAILED'],
            requestCount: requestCount,
          );
        }
        await _store.putRun(
          run.copyWith(
            state: AiRunState.success,
            attemptCount: requestCount,
            finishedAt: DateTime.now(),
          ),
        );
        onState?.call(AiRunState.success);
        return AiTaskResult(
          ok: true,
          runId: runId,
          snapshot: snapshot,
          formal: entry,
          validation: lastValidation,
          requestCount: requestCount,
        );
      }

      if (contentRepairs >= effective.contentRepairLimit) {
        final codes = lastValidation.errors.map((e) => e.code).toSet().toList();
        debugPrint(
          '[AI] validation failed codes=$codes '
          'errors=${lastValidation.errors.map((e) => e.toJson()).toList()}',
        );
        await _store.putRun(
          run.copyWith(
            state: AiRunState.failed,
            attemptCount: requestCount,
            finishedAt: DateTime.now(),
            errorCodes: codes,
            detail: '内容纠错次数已用完',
          ),
        );
        onState?.call(AiRunState.failed);
        return AiTaskResult(
          ok: false,
          runId: runId,
          snapshot: snapshot,
          validation: lastValidation,
          error: '校对结果没有通过校验，已显示原文',
          errorCodes: codes,
          requestCount: requestCount,
        );
      }

      contentRepairs++;
      if (messages.length > 8) {
        await _store.putRun(
          run.copyWith(
            state: AiRunState.failed,
            attemptCount: requestCount,
            finishedAt: DateTime.now(),
            errorCodes: const ['RETRY_CONTEXT_EXCEEDED'],
          ),
        );
        onState?.call(AiRunState.failed);
        return AiTaskResult(
          ok: false,
          runId: runId,
          snapshot: snapshot,
          validation: lastValidation,
          error: '纠错上下文过长，已停止',
          errorCodes: const ['RETRY_CONTEXT_EXCEEDED'],
          requestCount: requestCount,
        );
      }
      messages
        ..add({'role': 'assistant', 'content': text})
        ..add({
          'role': 'user',
          'content': _repairMessage(lastValidation.errors),
        });
      onState?.call(AiRunState.repairing);
    }
  }

  Future<_Gate?> _preflight({
    required String bookId,
    required AiEffectiveSettings effective,
    required bool automatic,
    required bool confirmedOverBudget,
    required AiRunKind kind,
  }) async {
    if (!effective.enabled) {
      return const _Gate('DISABLED', 'AI 阅读优化未开启');
    }
    if (_settings.device.deviceDisabled) {
      return const _Gate('DEVICE_DISABLED', '本机已停用 AI 请求');
    }
    if (!_settings.device.cloudConsent) {
      return const _Gate('CONSENT_REQUIRED', '还没有同意把章节正文发送给第三方');
    }
    final decision = await _budget.check(bookId: bookId, automatic: automatic);
    if (!decision.allowed) {
      return _Gate('BUDGET_EXCEEDED', decision.reason ?? '预算已达上限');
    }
    if (decision.needsConfirmation && !confirmedOverBudget) {
      return _Gate(
        'BUDGET_CONFIRM',
        decision.reason ?? '本次请求将超出预算',
        needsBudgetConfirmation: true,
      );
    }
    return null;
  }

  String _repairMessage(List<AiValidationIssue> errors) {
    final payload = jsonEncode({
      'code': 'OUTPUT_VALIDATION_FAILED',
      'errors': errors.map((e) => e.toJson()).toList(),
    });
    return '请重新生成完整 JSON 对象和完整 edits 数组，保留正确项并修复全部错误。\n'
        '不要把错误项删掉后只返回剩余项；不要输出解释。\n'
        '$payload\n'
        '重复 original 必须扩大包含未改上下文的片段；replacement 同时保留对应未改上下文；'
        '所有项不得重叠，且 original 必须完整落在一个段落内。';
  }

  AiFormalCacheEntry _formalEntry({
    required String bookId,
    required AiChapterSnapshot snapshot,
    required String runId,
    required List<AiRawEdit> edits,
    required int generation,
    required String model,
    required String promptHash,
  }) {
    final encoded = jsonEncode(edits.map((e) => e.toJson()).toList());
    return AiFormalCacheEntry(
      bookId: bookId,
      canonicalHash: snapshot.canonicalHash,
      canonicalVersion: snapshot.canonicalVersion,
      activeRunId: runId,
      edits: List.unmodifiable(edits),
      status: edits.isEmpty ? 'success_empty' : 'success',
      generation: generation,
      updatedAt: DateTime.now(),
      sourceUtf16Length: snapshot.sourceUtf16Length,
      paragraphBoundaryFingerprint: snapshot.paragraphBoundaryFingerprint,
      integrityHash: _sha(encoded),
      model: model,
      promptHash: promptHash,
    );
  }

  String _configHash(
    AiEffectiveSettings effective,
    AiProviderProfile provider,
    String model,
  ) => _sha(
    jsonEncode({
      'provider': provider.id,
      'endpoint': provider.baseUrl,
      'model': model,
      'mode': provider.outputMode.wire,
      'temperature': provider.temperature,
      'reasoningEffort': provider.reasoningEffort.name,
      'prompt': effective.behaviorPrompt,
    }),
  );

  static String _sha(String value) {
    // Avoid importing crypto in this orchestration file; the snapshot already
    // provides SHA-256 for content. A stable non-crypto config digest is enough
    // for metadata, while integrity comes from the formal record's content.
    var hash = 2166136261;
    for (final code in value.codeUnits) {
      hash ^= code;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  static String _newId(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return '${prefix}_${base64Url.encode(bytes).replaceAll('=', '')}';
  }
}

class _Gate {
  const _Gate(this.code, this.message, {this.needsBudgetConfirmation = false});
  final String code;
  final String message;
  final bool needsBudgetConfirmation;
}
