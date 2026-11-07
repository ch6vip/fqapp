import 'dart:convert';

import 'package:archive/archive.dart';

import 'ai_models.dart';
import 'ai_budget.dart';
import 'ai_controller.dart';
import 'ai_settings.dart';
import 'ai_store.dart';

class AiBackupPayload {
  const AiBackupPayload({
    required this.feedback,
    required this.prompts,
    required this.candidates,
    required this.trials,
    required this.trialResults,
    required this.usage,
    required this.pending,
    required this.createdAt,
    this.globalPrompt,
    this.bookPrompts = const {},
    this.rates = const [],
  });

  final List<AiFeedbackAggregate> feedback;
  final List<AiPromptRecord> prompts;
  final List<AiPromptCandidate> candidates;
  final List<AiTrialRecord> trials;
  final List<AiTrialResultRecord> trialResults;
  final List<AiBudgetProjection> usage;
  final List<AiPendingBinding> pending;
  final DateTime createdAt;
  final String? globalPrompt;
  final Map<String, String> bookPrompts;
  final List<AiRateProfile> rates;

  Map<String, dynamic> toJson() => {
    'format': 'fqapp.ai-backup',
    'version': 1,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'feedback': feedback.map((e) => e.toJson()).toList(),
    'prompts': prompts.map((e) => e.toJson()).toList(),
    'candidates': candidates.map((e) => e.toJson()).toList(),
    'trials': trials.map((e) => e.toJson()).toList(),
    'trialResults': [
      for (final result in trialResults)
        AiTrialResultRecord(
          trialId: result.trialId,
          chapterId: result.chapterId,
          canonicalHash: result.canonicalHash,
          runId: result.runId,
          // Portable backups keep the summary and verdicts, never the raw
          // model output or the per-request ledger.
          rawValidatedEdits: null,
          validationStatus: result.validationStatus,
          perFeedback: result.perFeedback,
          createdAt: result.createdAt,
        ).toJson(),
    ],
    'usage': usage.map((e) => e.toJson()).toList(),
    'pending': pending.map((e) => e.toJson()).toList(),
    'promptState': {
      if (globalPrompt != null) 'global': globalPrompt,
      if (bookPrompts.isNotEmpty) 'books': bookPrompts,
    },
    if (rates.isNotEmpty) 'rates': rates.map((rate) => rate.toJson()).toList(),
  };

  static AiBackupPayload fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('AI 备份分段结构无效');
    final map = raw.map((key, value) => MapEntry('$key', value));
    if (map['format'] != 'fqapp.ai-backup' || map['version'] != 1) {
      throw const FormatException('不是受支持的 AI 备份分段');
    }
    // Feedback, prompt history and candidates are user assets. A truncated
    // file must be rejected before any box is touched.
    for (final required in ['feedback', 'prompts', 'candidates']) {
      if (map[required] is! List) {
        throw FormatException('AI 备份缺少必需分段：$required');
      }
    }
    List<Map<String, dynamic>> maps(String key) {
      final value = map[key];
      if (value == null) return const [];
      if (value is! List) throw FormatException('AI 备份字段 $key 无效');
      return [
        for (final entry in value)
          if (entry is Map)
            entry.map((k, v) => MapEntry('$k', v))
          else
            throw FormatException('AI 备份字段 $key 含无效项'),
      ];
    }

    final promptState = map['promptState'] is Map
        ? (map['promptState'] as Map).map((k, v) => MapEntry('$k', v))
        : const <String, dynamic>{};
    final rawBookPrompts = promptState['books'];
    final bookPrompts = <String, String>{};
    if (rawBookPrompts is Map) {
      for (final entry in rawBookPrompts.entries) {
        if (entry.value is String) {
          bookPrompts['${entry.key}'] = entry.value as String;
        }
      }
    }

    return AiBackupPayload(
      feedback: [
        for (final entry in maps('feedback'))
          if (AiFeedbackAggregate.fromJson(entry) case final parsed?)
            parsed
          else
            throw const FormatException('AI 备份含损坏的反馈'),
      ],
      prompts: [
        for (final entry in maps('prompts'))
          if (AiPromptRecord.fromJson(entry) case final parsed?)
            parsed
          else
            throw const FormatException('AI 备份含损坏的提示词'),
      ],
      candidates: [
        for (final entry in maps('candidates'))
          if (AiPromptCandidate.fromJson(entry) case final parsed?)
            parsed
          else
            throw const FormatException('AI 备份含损坏的提示词候选'),
      ],
      trials: [
        for (final entry in maps('trials'))
          if (AiTrialRecord.fromJson(entry) case final parsed?)
            parsed
          else
            throw const FormatException('AI 备份含损坏的试验'),
      ],
      trialResults: [
        for (final entry in maps('trialResults'))
          if (AiTrialResultRecord.fromJson(entry) case final parsed?)
            AiTrialResultRecord(
              trialId: parsed.trialId,
              chapterId: parsed.chapterId,
              canonicalHash: parsed.canonicalHash,
              runId: parsed.runId,
              // Raw model output is deliberately not part of a portable backup.
              rawValidatedEdits: null,
              validationStatus: parsed.validationStatus,
              perFeedback: parsed.perFeedback,
              createdAt: parsed.createdAt,
            )
          else
            throw const FormatException('AI 备份含损坏的试验判定'),
      ],
      usage: [
        for (final entry in maps('usage'))
          if (AiBudgetProjection.fromJson(entry) case final parsed?)
            parsed
          else
            throw const FormatException('AI 备份含损坏的用量聚合'),
      ],
      pending: [
        for (final entry in maps('pending'))
          if (AiPendingBinding.fromJson(entry) case final parsed?)
            parsed
          else
            throw const FormatException('AI 备份含损坏的待绑定资产'),
      ],
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['createdAt'] is int
            ? map['createdAt'] as int
            : DateTime.now().millisecondsSinceEpoch,
      ),
      globalPrompt: promptState['global'] is String
          ? promptState['global'] as String
          : null,
      bookPrompts: Map.unmodifiable(bookPrompts),
      rates: [
        for (final entry in maps('rates'))
          if (AiRateProfile.fromJson(entry) case final parsed?)
            parsed
          else
            throw const FormatException('AI 备份含损坏的费率配置'),
      ],
    );
  }
}

class AiBackupService {
  AiBackupService({AiStore? store, AiSettingsStore? settings})
    : _store = store ?? AiStore.instance,
      _settings = settings ?? AiSettingsStore.instance;

  static final instance = AiBackupService();
  final AiStore _store;
  final AiSettingsStore _settings;

  Future<Set<String>> bookIdsWithAssets() async {
    final ids = <String>{};
    for (final aggregate in await _store.allAggregates()) {
      ids.add(aggregate.bookId);
    }
    for (final prompt in await _store.prompts()) {
      if (prompt.bookId != null) ids.add(prompt.bookId!);
    }
    for (final candidate in await _store.candidates()) {
      ids.add(candidate.bookId);
    }
    for (final trial in await _store.trials()) {
      ids.add(trial.bookId);
    }
    return ids.toSet();
  }

  Future<AiBackupPayload> capture({
    String? bookId,
    bool includeTrialDetails = true,
  }) async {
    final allFeedback = await _store.allAggregates();
    final allPrompts = await _store.prompts();
    final allCandidates = await _store.candidates();
    final allTrials = await _store.trials();
    final allTrialResults = await _store.trialResults();
    final usage = await _store.projections();
    final allPending = await _store.pendingBindings();
    final feedback = bookId == null
        ? allFeedback
        : allFeedback.where((item) => item.bookId == bookId).toList();
    final prompts = bookId == null
        ? allPrompts
        : allPrompts.where((item) => item.bookId == bookId).toList();
    final candidates = bookId == null
        ? allCandidates
        : allCandidates.where((item) => item.bookId == bookId).toList();
    final trials = includeTrialDetails
        ? (bookId == null
              ? allTrials
              : allTrials.where((item) => item.bookId == bookId).toList())
        : const <AiTrialRecord>[];
    final trialIds = trials.map((item) => item.trialId).toSet();
    final trialResults = includeTrialDetails
        ? allTrialResults
              .where((item) => trialIds.contains(item.trialId))
              .toList()
        : const <AiTrialResultRecord>[];
    final pending = bookId == null
        ? allPending
        : allPending.where((item) => item.aggregate.bookId == bookId).toList();
    final bookPrompts = <String, String>{};
    for (final entry in _settings.allBookOverrides.entries) {
      if (bookId != null && entry.key != bookId) continue;
      final value = entry.value['behaviorPrompt'];
      if (value is String) bookPrompts[entry.key] = value;
    }
    return AiBackupPayload(
      feedback: feedback,
      prompts: prompts,
      candidates: candidates,
      trials: trials,
      trialResults: trialResults,
      usage: usage,
      pending: pending,
      createdAt: DateTime.now(),
      globalPrompt: _settings.global.behaviorPrompt,
      bookPrompts: Map.unmodifiable(bookPrompts),
      rates: _settings.rates,
    );
  }

  /// Gzip + base64 for embedding in the portable v2 library backup. Gzip
  /// keeps feedback revisions and prompt history well below the 16 MB cap.
  Future<String> encode({
    String? bookId,
    bool includeTrialDetails = true,
  }) async {
    final payload = await capture(
      bookId: bookId,
      includeTrialDetails: includeTrialDetails,
    );
    final bytes = utf8.encode(jsonEncode(payload.toJson()));
    final compressed = GZipEncoder().encode(bytes);
    return base64Encode(compressed);
  }

  /// Full preflight before any write. Missing mandatory sections are rejected;
  /// optional trial summary/usage may be empty but never silently dropped from
  /// a section that exists.
  Future<AiBackupRestoreResult> decodeAndRestore(String encoded) async {
    final bytes = base64Decode(encoded);
    final unpacked = GZipDecoder().decodeBytes(bytes);
    final payload = AiBackupPayload.fromJson(jsonDecode(utf8.decode(unpacked)));
    return restore(payload);
  }

  /// Decode and validate the AI section without writing anything. The outer
  /// library restore calls this before it touches shelf/history boxes.
  Future<AiBackupRestorePlan> prepareEncoded(String encoded) async {
    final bytes = base64Decode(encoded);
    final unpacked = GZipDecoder().decodeBytes(bytes);
    final payload = AiBackupPayload.fromJson(jsonDecode(utf8.decode(unpacked)));
    return prepare(payload);
  }

  /// Phase 1: compute every merge/validation in memory, before the first write.
  Future<AiBackupRestorePlan> prepare(AiBackupPayload payload) async {
    final aggregatePlans = <AiBackupAggregatePlan>[];
    for (final aggregate in payload.feedback) {
      if (aggregate.bookId.startsWith('local_')) continue;
      final current = await _store.aggregate(
        bookId: aggregate.bookId,
        chapterId: aggregate.chapterId,
        canonicalVersion: aggregate.canonicalVersion,
        canonicalHash: aggregate.canonicalHash,
      );
      final merged = current == null
          ? aggregate
          : _mergeAggregate(current, aggregate);
      _store.validateAggregateForRestore(merged);
      aggregatePlans.add(
        AiBackupAggregatePlan(
          incoming: aggregate,
          merged: merged,
          expectedRevision: current?.aggregateRevision ?? 0,
        ),
      );
    }

    // Local books get a new ID after every import. Keep their assets pending
    // until the user explicitly matches the chapter hash.
    final pendingBindings = <AiPendingBinding>[];
    for (final aggregate in payload.feedback) {
      if (!aggregate.bookId.startsWith('local_')) continue;
      pendingBindings.add(
        AiPendingBinding(
          id: '${aggregate.bookId}:${aggregate.chapterId}:${aggregate.canonicalHash.substring(0, 8)}',
          sourceBookId: aggregate.bookId,
          sourceChapterId: aggregate.chapterId,
          title: aggregate.chapterId,
          canonicalHash: aggregate.canonicalHash,
          canonicalVersion: aggregate.canonicalVersion,
          aggregate: aggregate,
          createdAt: DateTime.now(),
        ),
      );
    }
    for (final binding in payload.pending) {
      pendingBindings.add(binding);
    }

    // Prompt history is immutable by promptId. Never let an older backup flip
    // a locally revoked prompt back to active.
    final existingPromptIds = (await _store.prompts())
        .map((prompt) => prompt.promptId)
        .toSet();
    final promptsToWrite = payload.prompts
        .where((prompt) => !existingPromptIds.contains(prompt.promptId))
        .toList(growable: false);
    final existingCandidateIds = (await _store.candidates())
        .map((candidate) => candidate.candidateId)
        .toSet();
    final candidatesToWrite = payload.candidates
        .where(
          (candidate) => !existingCandidateIds.contains(candidate.candidateId),
        )
        .toList(growable: false);

    return AiBackupRestorePlan(
      payload: payload,
      aggregatePlans: aggregatePlans,
      pendingBindings: pendingBindings,
      promptsToWrite: promptsToWrite,
      candidatesToWrite: candidatesToWrite,
    );
  }

  /// Phase 2: commit a plan produced by [prepare]. No validation that can fail
  /// on malformed input is left for this phase.
  Future<AiBackupRestoreResult> commit(AiBackupRestorePlan plan) async {
    final payload = plan.payload;
    var feedback = 0;
    var prompts = 0;
    var candidates = 0;
    var trials = 0;
    var trialResults = 0;
    var usage = 0;
    var pending = 0;
    var conflicts = 0;

    for (final aggregatePlan in plan.aggregatePlans) {
      // The queue and revision check are inside the store. If a local edit
      // landed after prepare(), merge it with the incoming snapshot again
      // instead of overwriting the newer chapter.
      final restored = await _store.mutateAggregate(
        bookId: aggregatePlan.incoming.bookId,
        chapterId: aggregatePlan.incoming.chapterId,
        canonicalVersion: aggregatePlan.incoming.canonicalVersion,
        canonicalHash: aggregatePlan.incoming.canonicalHash,
        mutate: (current) {
          if (current == null ||
              current.aggregateRevision == aggregatePlan.expectedRevision) {
            return aggregatePlan.merged;
          }
          final remerged = _mergeAggregate(current, aggregatePlan.incoming);
          _store.validateAggregateForRestore(remerged);
          return remerged;
        },
      );
      conflicts += restored.conflicts.length;
      feedback++;
    }
    for (final prompt in plan.promptsToWrite) {
      await _store.putPrompt(prompt);
      prompts++;
    }
    for (final candidate in plan.candidatesToWrite) {
      await _store.putCandidate(candidate);
      candidates++;
    }
    for (final trial in payload.trials) {
      await _store.putTrial(trial);
      trials++;
    }
    for (final result in payload.trialResults) {
      final current = await _store.trialResult(
        result.trialId,
        result.chapterId,
      );
      // Portable backups deliberately omit raw model edits. Never let such a
      // summary replace a locally retained raw result and break re-scoring.
      final merged = current == null
          ? result
          : AiTrialResultRecord(
              trialId: result.trialId,
              chapterId: result.chapterId,
              canonicalHash: result.canonicalHash,
              runId: current.runId,
              rawValidatedEdits:
                  current.rawValidatedEdits ?? result.rawValidatedEdits,
              validationStatus: current.validationStatus,
              perFeedback: current.perFeedback.isNotEmpty
                  ? current.perFeedback
                  : result.perFeedback,
              createdAt: current.createdAt,
            );
      await _store.putTrialResult(merged);
      trialResults++;
    }
    for (final projection in payload.usage) {
      // Same serialized budget queue as live requests: an older backup snapshot
      // must not overwrite a request that reserved or settled concurrently.
      await AiBudgetService.instance.mergeUsage(projection);
      usage++;
    }
    for (final binding in plan.pendingBindings) {
      await _store.putPending(binding);
      pending++;
    }

    for (final rate in payload.rates) {
      final current = _settings.rate(rate.id);
      if (current == null || rate.updatedAt.isAfter(current.updatedAt)) {
        await _settings.upsertRate(rate);
      }
    }

    // Restore prompt overrides only when the target device has no value yet;
    // never overwrite a prompt the user already configured locally.
    if (payload.globalPrompt != null &&
        _settings.global.behaviorPrompt == null) {
      await _settings.saveGlobal(
        _settings.global.copyWith(behaviorPrompt: payload.globalPrompt),
      );
    }
    for (final entry in payload.bookPrompts.entries) {
      if (_settings.bookOverrides(entry.key).containsKey('behaviorPrompt')) {
        continue;
      }
      await _settings.setBookOverride(entry.key, 'behaviorPrompt', entry.value);
    }

    AiReadingController.instance.notifyExternalDataChanged();
    return AiBackupRestoreResult(
      feedback: feedback,
      prompts: prompts,
      candidates: candidates,
      trials: trials,
      trialResults: trialResults,
      usage: usage,
      pending: pending,
      conflicts: conflicts,
    );
  }

  Future<AiBackupRestoreResult> restore(AiBackupPayload payload) async {
    return commit(await prepare(payload));
  }

  static AiFeedbackAggregate _mergeAggregate(
    AiFeedbackAggregate current,
    AiFeedbackAggregate incoming,
  ) {
    final cases = <String, AiFeedbackCase>{
      for (final entry in current.cases) entry.feedbackId: entry,
    };
    final protections = <String, AiFeedbackProtection>{
      for (final entry in current.protections) entry.protectionId: entry,
    };
    final conflicts = <String, AiRestoreConflict>{
      for (final entry in [...current.conflicts, ...incoming.conflicts])
        entry.signature: entry,
    };
    for (final entry in incoming.cases) {
      final existing = cases[entry.feedbackId];
      if (existing == null) {
        cases[entry.feedbackId] = entry;
        continue;
      }
      if (existing.caseRevision == entry.caseRevision &&
          jsonEncode(existing.toJson()) != jsonEncode(entry.toJson())) {
        _addConflict(
          conflicts,
          'case',
          entry.feedbackId,
          existing.toJson(),
          entry.toJson(),
        );
        continue;
      }
      if (_preferCase(entry, existing)) {
        cases[entry.feedbackId] = entry;
      }
    }
    for (final entry in incoming.protections) {
      final existing = protections[entry.protectionId];
      if (existing == null) {
        protections[entry.protectionId] = entry;
        continue;
      }
      if (existing.sourceFeedbackRevision == entry.sourceFeedbackRevision &&
          jsonEncode(existing.toJson()) != jsonEncode(entry.toJson())) {
        _addConflict(
          conflicts,
          'protection',
          entry.protectionId,
          existing.toJson(),
          entry.toJson(),
        );
        continue;
      }
      if (_preferProtection(entry, existing)) {
        protections[entry.protectionId] = entry;
      }
    }
    final revision = current.aggregateRevision > incoming.aggregateRevision
        ? current.aggregateRevision
        : incoming.aggregateRevision;
    return AiFeedbackAggregate(
      bookId: current.bookId,
      chapterId: current.chapterId,
      canonicalVersion: current.canonicalVersion,
      canonicalHash: current.canonicalHash,
      aggregateRevision: revision + 1,
      cases: List.unmodifiable(cases.values),
      protections: List.unmodifiable(protections.values),
      conflicts: List.unmodifiable(conflicts.values),
      updatedAt: DateTime.now(),
    );
  }

  static bool _preferCase(AiFeedbackCase next, AiFeedbackCase current) =>
      next.caseRevision > current.caseRevision;

  static bool _preferProtection(
    AiFeedbackProtection next,
    AiFeedbackProtection current,
  ) => next.sourceFeedbackRevision > current.sourceFeedbackRevision;

  static void _addConflict(
    Map<String, AiRestoreConflict> conflicts,
    String kind,
    String itemId,
    Map<String, dynamic> local,
    Map<String, dynamic> incoming,
  ) {
    final conflict = AiRestoreConflict(
      kind: kind,
      itemId: itemId,
      localJson: jsonEncode(local),
      incomingJson: jsonEncode(incoming),
      detectedAt: DateTime.now(),
    );
    conflicts.putIfAbsent(conflict.signature, () => conflict);
  }
}

class AiBackupAggregatePlan {
  const AiBackupAggregatePlan({
    required this.incoming,
    required this.merged,
    required this.expectedRevision,
  });

  final AiFeedbackAggregate incoming;
  final AiFeedbackAggregate merged;
  final int expectedRevision;
}

class AiBackupRestorePlan {
  const AiBackupRestorePlan({
    required this.payload,
    required this.aggregatePlans,
    required this.pendingBindings,
    required this.promptsToWrite,
    required this.candidatesToWrite,
  });

  final AiBackupPayload payload;
  final List<AiBackupAggregatePlan> aggregatePlans;
  final List<AiPendingBinding> pendingBindings;
  final List<AiPromptRecord> promptsToWrite;
  final List<AiPromptCandidate> candidatesToWrite;
}

class AiBackupRestoreResult {
  const AiBackupRestoreResult({
    required this.feedback,
    required this.prompts,
    required this.candidates,
    required this.trials,
    required this.trialResults,
    required this.usage,
    required this.pending,
    required this.conflicts,
  });

  final int feedback;
  final int prompts;
  final int candidates;
  final int trials;
  final int trialResults;
  final int usage;
  final int pending;
  final int conflicts;

  int get total =>
      feedback +
      prompts +
      candidates +
      trials +
      trialResults +
      usage +
      pending +
      conflicts;

  String get summary =>
      '已恢复 $feedback 章反馈、$prompts 条提示词、$candidates 个候选、'
      '$trials 次试验、$trialResults 条试验判定、$usage 个用量聚合'
      '${pending > 0 ? '；$pending 条本地书资产待绑定' : ''}'
      '${conflicts > 0 ? '；$conflicts 条恢复冲突待处理' : ''}';
}
