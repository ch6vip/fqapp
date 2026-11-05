import 'dart:convert';

import 'package:archive/archive.dart';

import 'ai_models.dart';
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
      if (!map.containsKey(required)) {
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
        for (final entry in maps('prompts')) ?AiPromptRecord.fromJson(entry),
      ],
      candidates: [
        for (final entry in maps('candidates'))
          ?AiPromptCandidate.fromJson(entry),
      ],
      trials: [
        for (final entry in maps('trials')) ?AiTrialRecord.fromJson(entry),
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
            ),
      ],
      usage: [
        for (final entry in maps('usage')) ?AiBudgetProjection.fromJson(entry),
      ],
      pending: [
        for (final entry in maps('pending')) ?AiPendingBinding.fromJson(entry),
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
        for (final entry in maps('rates')) ?AiRateProfile.fromJson(entry),
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

  Future<AiBackupRestoreResult> restore(AiBackupPayload payload) async {
    var feedback = 0;
    var prompts = 0;
    var candidates = 0;
    var trials = 0;
    var trialResults = 0;
    var usage = 0;
    var pending = 0;

    // Phase 1: compute every merged aggregate in memory and validate it before
    // the first write. This prevents an invalid file from leaving a partial
    // restore behind.
    final mergedFeedback = <AiFeedbackAggregate>[];
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
      mergedFeedback.add(merged);
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

    // Phase 2: commit. Aggregate snapshots are one key each; a newer local
    // revision is never replaced by an older backup revision.
    for (final aggregate in mergedFeedback) {
      await _store.putAggregate(aggregate);
      feedback++;
    }
    for (final prompt in payload.prompts) {
      await _store.putPrompt(prompt);
      prompts++;
    }
    for (final candidate in payload.candidates) {
      await _store.putCandidate(candidate);
      candidates++;
    }
    for (final trial in payload.trials) {
      await _store.putTrial(trial);
      trials++;
    }
    for (final result in payload.trialResults) {
      await _store.putTrialResult(result);
      trialResults++;
    }
    for (final projection in payload.usage) {
      final current = await _store.projection(
        projection.bucketDay,
        projection.bookId,
      );
      // Usage is a monotonic ledger projection. Restoring an older backup must
      // not lower today's spend and silently reopen the budget.
      if (current == null ||
          projection.requestCount > current.requestCount ||
          projection.tokenSum > current.tokenSum ||
          projection.costMicros > current.costMicros) {
        await _store.putProjection(
          current == null
              ? projection
              : projection.copyWith(
                  requestCount: projection.requestCount > current.requestCount
                      ? projection.requestCount
                      : current.requestCount,
                  taskCount: projection.taskCount > current.taskCount
                      ? projection.taskCount
                      : current.taskCount,
                  tokenSum: projection.tokenSum > current.tokenSum
                      ? projection.tokenSum
                      : current.tokenSum,
                  unknownUsageCount:
                      projection.unknownUsageCount > current.unknownUsageCount
                      ? projection.unknownUsageCount
                      : current.unknownUsageCount,
                  costMicros: projection.costMicros > current.costMicros
                      ? projection.costMicros
                      : current.costMicros,
                ),
        );
      }
      usage++;
    }
    for (final binding in pendingBindings) {
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
    );
  }

  static AiFeedbackAggregate _mergeAggregate(
    AiFeedbackAggregate current,
    AiFeedbackAggregate incoming,
  ) {
    final cases = <String, AiFeedbackCase>{
      for (final entry in current.cases) entry.feedbackId: entry,
    };
    for (final entry in incoming.cases) {
      final existing = cases[entry.feedbackId];
      if (existing == null || _preferCase(entry, existing)) {
        cases[entry.feedbackId] = entry;
      }
    }
    final protections = <String, AiFeedbackProtection>{
      for (final entry in current.protections) entry.protectionId: entry,
    };
    for (final entry in incoming.protections) {
      final existing = protections[entry.protectionId];
      if (existing == null || _preferProtection(entry, existing)) {
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
      updatedAt: DateTime.now(),
    );
  }

  static bool _preferCase(AiFeedbackCase next, AiFeedbackCase current) {
    if (next.caseRevision != current.caseRevision) {
      return next.caseRevision > current.caseRevision;
    }
    final nextTerminal =
        next.status == AiFeedbackStatus.deleted ||
        next.status == AiFeedbackStatus.superseded;
    final currentTerminal =
        current.status == AiFeedbackStatus.deleted ||
        current.status == AiFeedbackStatus.superseded;
    if (nextTerminal != currentTerminal) return nextTerminal;
    return next.updatedAt.isAfter(current.updatedAt);
  }

  static bool _preferProtection(
    AiFeedbackProtection next,
    AiFeedbackProtection current,
  ) {
    final nextTerminal = next.status != AiProtectionStatus.active;
    final currentTerminal = current.status != AiProtectionStatus.active;
    if (nextTerminal != currentTerminal) return nextTerminal;
    return next.updatedAt.isAfter(current.updatedAt);
  }
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
  });

  final int feedback;
  final int prompts;
  final int candidates;
  final int trials;
  final int trialResults;
  final int usage;
  final int pending;

  int get total =>
      feedback + prompts + candidates + trials + trialResults + usage + pending;

  String get summary =>
      '已恢复 $feedback 章反馈、$prompts 条提示词、$candidates 个候选、'
      '$trials 次试验、$trialResults 条试验判定、$usage 个用量聚合'
      '${pending > 0 ? '；$pending 条本地书资产待绑定' : ''}';
}
