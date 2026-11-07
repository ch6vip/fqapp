import 'dart:async';
import 'dart:convert';

import 'package:hive_ce/hive.dart';

import '../encrypted_hive.dart';
import 'ai_models.dart';

/// Encrypted persistence for the AI reading feature.
///
/// Formal results, feedback/protection aggregates, prompts, trials and usage
/// are deliberately separate boxes. A formal cache write can never overwrite a
/// feedback asset, and a feedback aggregate is one atomic chapter snapshot.
class AiStore {
  AiStore._();
  static final instance = AiStore._();

  static const formalBoxName = 'ai_formal_v1';
  static const runsBoxName = 'ai_runs_v1';
  static const requestsBoxName = 'ai_requests_v1';
  static const feedbackBoxName = 'ai_feedback_chapter_v1';
  static const promptsBoxName = 'ai_prompts_v1';
  static const candidatesBoxName = 'ai_candidates_v1';
  static const trialsBoxName = 'ai_trials_v1';
  static const trialResultsBoxName = 'ai_trial_results_v1';
  static const usageBoxName = 'ai_usage_aggregate_v1';
  static const pendingBoxName = 'ai_pending_bindings_v1';
  static const chapterStatusBoxName = 'ai_chapter_status_v1';
  static const metaBoxName = 'ai_meta_v1';

  static const _formalEpochKey = 'formalEpoch';
  static const _bookEpochPrefix = 'bookEpoch:';
  static const _hashEpochPrefix = 'hashEpoch:';

  Box<dynamic>? _formal;
  Box<dynamic>? _runs;
  Box<dynamic>? _requests;
  Box<dynamic>? _feedback;
  Box<dynamic>? _prompts;
  Box<dynamic>? _candidates;
  Box<dynamic>? _trials;
  Box<dynamic>? _trialResults;
  Box<dynamic>? _usage;
  Box<dynamic>? _pending;
  Box<dynamic>? _chapterStatus;
  Box<dynamic>? _meta;

  Future<void>? _initFuture;
  bool _available = false;
  String? _status;
  final _queues = <String, Future<void>>{};

  bool get isAvailable => _available;
  String? get status => _status;

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      final opened = await Future.wait([
        EncryptedHive.openBox<dynamic>(
          Hive,
          formalBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          runsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          requestsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          feedbackBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          promptsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          candidatesBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          trialsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          trialResultsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          usageBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          pendingBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          chapterStatusBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          metaBoxName,
          requireEncryption: true,
        ),
      ]);
      _formal = opened[0];
      _runs = opened[1];
      _requests = opened[2];
      _feedback = opened[3];
      _prompts = opened[4];
      _candidates = opened[5];
      _trials = opened[6];
      _trialResults = opened[7];
      _usage = opened[8];
      _pending = opened[9];
      _chapterStatus = opened[10];
      _meta = opened[11];
      _available = true;
      _status = null;
    } catch (error) {
      _available = false;
      _status = 'AI 数据箱不可用：$error';
    }
  }

  // ── Formal cache ────────────────────────────────────────────────────────

  String formalKey(String bookId, String hash) => jsonEncode([bookId, hash]);

  /// Bumped before deleting formal entries. An in-flight write that started
  /// before the clear carries the old epoch and is rejected at commit time,
  /// so a paid result cannot resurrect a cache the user just removed.
  int get formalEpoch => (_meta?.get(_formalEpochKey) as int?) ?? 0;

  int bookEpoch(String bookId) =>
      (_meta?.get('$_bookEpochPrefix$bookId') as int?) ?? 0;

  String _hashEpochKey(String bookId, String hash) =>
      '$_hashEpochPrefix${jsonEncode([bookId, hash])}';

  int hashEpoch(String bookId, String hash) =>
      (_meta?.get(_hashEpochKey(bookId, hash)) as int?) ?? 0;

  Future<void> _bumpFormalEpoch() async {
    await _meta?.put(_formalEpochKey, formalEpoch + 1);
  }

  Future<void> _bumpBookEpoch(String bookId) async {
    await _meta?.put('$_bookEpochPrefix$bookId', bookEpoch(bookId) + 1);
  }

  Future<void> _bumpHashEpoch(String bookId, String hash) async {
    await _meta?.put(_hashEpochKey(bookId, hash), hashEpoch(bookId, hash) + 1);
  }

  Future<AiFormalCacheEntry?> formal(String bookId, String hash) async {
    if (!_available) return null;
    final raw = _formal?.get(formalKey(bookId, hash));
    final entry = AiFormalCacheEntry.fromJson(raw);
    if (entry == null) return null;
    // A stale schema, a mismatched hash, or damaged edits are all cache misses.
    if (entry.canonicalVersion != 1 || entry.canonicalHash != hash) return null;
    final encoded = jsonEncode(entry.edits.map((e) => e.toJson()).toList());
    if (entry.integrityHash != aiIntegrityHash(encoded)) return null;
    return entry;
  }

  /// Commits one formal result with a generation CAS.
  ///
  /// The compare and the write run on the same per-key queue, so a slower
  /// request cannot overwrite a newer refresh. Equal-generation writes from a
  /// different run are also rejected; the stored result wins.
  Future<bool> putFormal(AiFormalCacheEntry entry) async {
    if (!_available) throw StateError(_status ?? 'AI 数据箱不可用');
    final key = formalKey(entry.bookId, entry.canonicalHash);
    final queueKey = 'formal:$key';
    final previous = _queues[queueKey] ?? Future<void>.value();
    final completer = Completer<bool>();
    _queues[queueKey] = previous.then((_) async {
      try {
        final current = AiFormalCacheEntry.fromJson(_formal?.get(key));
        if (entry.cacheEpoch < formalEpoch ||
            entry.bookEpoch < bookEpoch(entry.bookId) ||
            entry.hashEpoch < hashEpoch(entry.bookId, entry.canonicalHash)) {
          if (!completer.isCompleted) completer.complete(false);
          return;
        }
        if (current != null && entry.generation < current.generation) {
          if (!completer.isCompleted) completer.complete(false);
          return;
        }
        if (current != null &&
            entry.generation == current.generation &&
            current.activeRunId != entry.activeRunId) {
          if (!completer.isCompleted) completer.complete(false);
          return;
        }
        await _formal?.put(key, entry.toJson());
        if (!completer.isCompleted) completer.complete(true);
      } catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> deleteFormal(String bookId, String hash) async {
    await _bumpHashEpoch(bookId, hash);
    await _formal?.delete(formalKey(bookId, hash));
  }

  /// Drops every formal correction result for the selected books, together
  /// with the per-chapter status rows that point at those results. Feedback,
  /// protections, prompts and usage ledgers live in other boxes and are left
  /// untouched.
  Future<void> clearFormalForBooks(Set<String> bookIds) async {
    if (bookIds.isEmpty) return;
    for (final bookId in bookIds) {
      await _bumpBookEpoch(bookId);
    }
    final formalKeys = <dynamic>[];
    for (final key in _formal?.keys.toList() ?? const []) {
      final entry = AiFormalCacheEntry.fromJson(_formal?.get(key));
      if (entry != null && bookIds.contains(entry.bookId)) {
        formalKeys.add(key);
      }
    }
    if (formalKeys.isNotEmpty) await _formal?.deleteAll(formalKeys);

    final statusKeys = <dynamic>[];
    for (final key in _chapterStatus?.keys.toList() ?? const []) {
      final status = AiChapterCheckStatus.fromJson(_chapterStatus?.get(key));
      if (status != null && bookIds.contains(status.bookId)) {
        statusKeys.add(key);
      }
    }
    if (statusKeys.isNotEmpty) await _chapterStatus?.deleteAll(statusKeys);
    if (formalKeys.isNotEmpty || statusKeys.isNotEmpty) {
      await _formal?.compact();
      await _chapterStatus?.compact();
    }
  }

  /// Drops the formal results selected by their content hash for one book.
  /// Every chapter status using the same hash is removed too, because the
  /// formal box is keyed by `(bookId, canonicalHash)` and those chapters share
  /// the same cached result.
  Future<void> clearFormalForHashes(String bookId, Set<String> hashes) async {
    if (hashes.isEmpty) return;
    for (final hash in hashes) {
      await _bumpHashEpoch(bookId, hash);
    }
    final keys = [for (final hash in hashes) formalKey(bookId, hash)];
    final existing = [
      for (final key in keys)
        if (_formal?.containsKey(key) ?? false) key,
    ];
    if (existing.isNotEmpty) await _formal?.deleteAll(existing);

    final statusKeys = <dynamic>[];
    for (final key in _chapterStatus?.keys.toList() ?? const []) {
      final status = AiChapterCheckStatus.fromJson(_chapterStatus?.get(key));
      if (status == null || status.bookId != bookId) continue;
      if (status.canonicalHash != null &&
          hashes.contains(status.canonicalHash)) {
        statusKeys.add(key);
      }
    }
    if (statusKeys.isNotEmpty) await _chapterStatus?.deleteAll(statusKeys);
    if (existing.isNotEmpty || statusKeys.isNotEmpty) {
      await _formal?.compact();
      await _chapterStatus?.compact();
    }
  }

  /// Drops every formal correction result. Feedback, protections, prompts and
  /// usage ledgers are separate assets and are intentionally untouched.
  Future<void> clearFormal() async {
    await _bumpFormalEpoch();
    await _formal?.clear();
    await _chapterStatus?.clear();
  }

  // ── Per-chapter status index ────────────────────────────────────────────

  String chapterStatusKey(String bookId, String chapterId) =>
      jsonEncode([bookId, chapterId]);

  Future<void> putChapterStatus(AiChapterCheckStatus status) async {
    if (!_available) return;
    await _chapterStatus?.put(
      chapterStatusKey(status.bookId, status.chapterId),
      status.toJson(),
    );
  }

  Future<AiChapterCheckStatus?> chapterStatus(
    String bookId,
    String chapterId,
  ) async {
    if (!_available) return null;
    return AiChapterCheckStatus.fromJson(
      _chapterStatus?.get(chapterStatusKey(bookId, chapterId)),
    );
  }

  Future<List<AiChapterCheckStatus>> chapterStatuses(String bookId) async {
    if (!_available) return const [];
    return [
      for (final value in _chapterStatus?.values ?? const [])
        if (AiChapterCheckStatus.fromJson(value) case final status?
            when status.bookId == bookId)
          status,
    ];
  }

  /// Runs left in a non-terminal state by a previous process are no longer in
  /// flight. Mark them interrupted so the ledger never shows a permanent
  /// spinner and so a request written before the terminal Run update stays
  /// explainable after a crash.
  Future<void> recoverInterruptedRuns() async {
    if (!_available) return;
    for (final run in await runs()) {
      if (run.state != AiRunState.running &&
          run.state != AiRunState.validating &&
          run.state != AiRunState.repairing) {
        continue;
      }
      await _runs?.put(
        run.runId,
        run
            .copyWith(
              state: AiRunState.interrupted,
              finishedAt: DateTime.now(),
              errorCodes: [
                ...run.errorCodes,
                if (!run.errorCodes.contains('INTERRUPTED')) 'INTERRUPTED',
              ],
              detail: '应用异常退出，已恢复未完成运行',
            )
            .toJson(),
      );
    }
  }

  /// A status left in [running] from a previous process is not actually in
  /// flight anymore. Keep it out of the directory's spinner state.
  Future<void> recoverInterruptedChapterStatuses() async {
    if (!_available) return;
    for (final key in _chapterStatus?.keys.toList() ?? const []) {
      final status = AiChapterCheckStatus.fromJson(_chapterStatus?.get(key));
      if (status == null || status.state != AiChapterCheckState.running) {
        continue;
      }
      await _chapterStatus?.put(
        key,
        status
            .copyWith(
              state: AiChapterCheckState.failed,
              errorCode: 'INTERRUPTED',
              updatedAt: DateTime.now(),
            )
            .toJson(),
      );
    }
  }

  Future<List<AiFormalCacheEntry>> allFormal() async {
    if (!_available) return const [];
    return [
      for (final value in _formal?.values ?? const [])
        ?AiFormalCacheEntry.fromJson(value),
    ];
  }

  // ── Runs / requests ─────────────────────────────────────────────────────

  Future<void> putRun(AiRunRecord run) async {
    await _runs?.put(run.runId, run.toJson());
  }

  Future<void> putRequest(AiRequestRecord request) async {
    await _requests?.put(request.requestId, request.toJson());
  }

  Future<AiRequestRecord?> request(String requestId) async {
    if (!_available) return null;
    return AiRequestRecord.fromJson(_requests?.get(requestId));
  }

  Future<List<AiRequestRecord>> requests() async {
    if (!_available) return const [];
    return [
      for (final value in _requests?.values ?? const [])
        ?AiRequestRecord.fromJson(value),
    ];
  }

  Future<AiRunRecord?> run(String runId) async {
    if (!_available) return null;
    return AiRunRecord.fromJson(_runs?.get(runId));
  }

  Future<List<AiRunRecord>> runs() async {
    if (!_available) return const [];
    return [
      for (final value in _runs?.values ?? const [])
        ?AiRunRecord.fromJson(value),
    ];
  }

  /// Explicit "clear usage ledger" action. Never touches feedback, protections,
  /// prompts or formal cache.
  Future<void> clearLedgers() async {
    await _requests?.clear();
    await _runs?.clear();
    await _usage?.clear();
  }

  // ── Feedback aggregate (single-key CAS) ─────────────────────────────────

  Future<AiFeedbackAggregate?> aggregate({
    required String bookId,
    required String chapterId,
    required int canonicalVersion,
    required String canonicalHash,
  }) async {
    if (!_available) return null;
    final key = jsonEncode([
      bookId,
      chapterId,
      canonicalVersion,
      canonicalHash,
    ]);
    final parsed = AiFeedbackAggregate.fromJson(_feedback?.get(key));
    if (parsed == null) return null;
    if (parsed.canonicalVersion != canonicalVersion ||
        parsed.canonicalHash != canonicalHash) {
      return null;
    }
    return parsed;
  }

  Future<List<AiFeedbackAggregate>> allAggregates() async {
    if (!_available) return const [];
    return [
      for (final value in _feedback?.values ?? const [])
        ?AiFeedbackAggregate.fromJson(value),
    ];
  }

  /// Serialises read-modify-write for one chapter snapshot. The callback gets
  /// the current aggregate (or null) and returns the next one; the store
  /// assigns `aggregateRevision` and writes the whole snapshot in one put.
  Future<AiFeedbackAggregate> mutateAggregate({
    required String bookId,
    required String chapterId,
    required int canonicalVersion,
    required String canonicalHash,
    required FutureOr<AiFeedbackAggregate> Function(
      AiFeedbackAggregate? current,
    )
    mutate,
  }) async {
    if (!_available) throw StateError(_status ?? 'AI 数据箱不可用');
    final key = jsonEncode([
      bookId,
      chapterId,
      canonicalVersion,
      canonicalHash,
    ]);
    final previous = _queues[key] ?? Future<void>.value();
    final completer = Completer<AiFeedbackAggregate>();
    _queues[key] = previous.then((_) async {
      try {
        final current = AiFeedbackAggregate.fromJson(_feedback?.get(key));
        var next = await mutate(current);
        // Preserve unresolved restore conflicts across every later mutation
        // of the same chapter aggregate. A normal feedback edit must not
        // silently erase the fact that two devices diverged.
        final conflicts = <String, AiRestoreConflict>{
          for (final entry in [...?current?.conflicts, ...next.conflicts])
            entry.signature: entry,
        };
        next = AiFeedbackAggregate(
          bookId: bookId,
          chapterId: chapterId,
          canonicalVersion: canonicalVersion,
          canonicalHash: canonicalHash,
          aggregateRevision: (current?.aggregateRevision ?? 0) + 1,
          cases: List.unmodifiable(next.cases),
          protections: List.unmodifiable(next.protections),
          conflicts: List.unmodifiable(conflicts.values),
          updatedAt: DateTime.now(),
        );
        _validateAggregate(next);
        await _feedback?.put(key, next.toJson());
        if (!completer.isCompleted) completer.complete(next);
      } catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  void _validateAggregate(AiFeedbackAggregate aggregate) {
    final ids = <String>{};
    for (final feedback in aggregate.cases) {
      if (!ids.add(feedback.feedbackId)) {
        throw StateError('反馈 ID 重复');
      }
    }
    final active = aggregate.activeProtections;
    for (var i = 0; i < active.length; i++) {
      for (var j = i + 1; j < active.length; j++) {
        final a = active[i];
        final b = active[j];
        if (a.sourceStart < b.sourceEnd && b.sourceStart < a.sourceEnd) {
          throw StateError('生效保护区间相交');
        }
      }
    }
  }

  /// Preflight validator for the backup importer. Running this before any
  /// write keeps an invalid file from partially mutating the asset boxes.
  void validateAggregateForRestore(AiFeedbackAggregate aggregate) =>
      _validateAggregate(aggregate);

  /// Restores a validated aggregate. Used only by the backup importer after a
  /// full preflight; normal UI writes go through [mutateAggregate].
  Future<void> putAggregate(AiFeedbackAggregate aggregate) async {
    _validateAggregate(aggregate);
    await _feedback?.put(aggregate.key, aggregate.toJson());
  }

  Future<void> deleteAggregate(AiFeedbackAggregate aggregate) async {
    await _feedback?.delete(aggregate.key);
  }

  // ── Prompts / candidates / trials ───────────────────────────────────────

  Future<void> putPrompt(AiPromptRecord prompt) async {
    await _prompts?.put(prompt.promptId, prompt.toJson());
  }

  Future<List<AiPromptRecord>> prompts() async {
    if (!_available) return const [];
    return [
      for (final value in _prompts?.values ?? const [])
        ?AiPromptRecord.fromJson(value),
    ];
  }

  Future<void> putCandidate(AiPromptCandidate candidate) async {
    await _candidates?.put(candidate.candidateId, candidate.toJson());
  }

  Future<List<AiPromptCandidate>> candidates() async {
    if (!_available) return const [];
    return [
      for (final value in _candidates?.values ?? const [])
        ?AiPromptCandidate.fromJson(value),
    ];
  }

  Future<void> putTrial(AiTrialRecord trial) async {
    await _trials?.put(trial.trialId, trial.toJson());
  }

  Future<List<AiTrialRecord>> trials() async {
    if (!_available) return const [];
    return [
      for (final value in _trials?.values ?? const [])
        ?AiTrialRecord.fromJson(value),
    ];
  }

  String trialResultKey(String trialId, String chapterId) =>
      jsonEncode([trialId, chapterId]);

  Future<AiTrialResultRecord?> trialResult(
    String trialId,
    String chapterId,
  ) async {
    if (!_available) return null;
    return AiTrialResultRecord.fromJson(
      _trialResults?.get(trialResultKey(trialId, chapterId)),
    );
  }

  Future<void> putTrialResult(AiTrialResultRecord result) async {
    await _trialResults?.put(
      trialResultKey(result.trialId, result.chapterId),
      result.toJson(),
    );
  }

  Future<List<AiTrialResultRecord>> trialResults([String? trialId]) async {
    if (!_available) return const [];
    return [
      for (final value in _trialResults?.values ?? const [])
        if (AiTrialResultRecord.fromJson(value) case final result?)
          if (trialId == null || result.trialId == trialId) result,
    ];
  }

  // ── Usage projections ───────────────────────────────────────────────────

  Future<AiBudgetProjection?> projection(String day, String? bookId) async {
    if (!_available) return null;
    return AiBudgetProjection.fromJson(_usage?.get(jsonEncode([day, bookId])));
  }

  Future<void> putProjection(AiBudgetProjection projection) async {
    final box = _usage;
    if (!_available || box == null) {
      throw StateError(_status ?? 'AI 用量存储不可用');
    }
    await box.put(projection.key, projection.toJson());
  }

  Future<List<AiBudgetProjection>> projections() async {
    if (!_available) return const [];
    return [
      for (final value in _usage?.values ?? const [])
        ?AiBudgetProjection.fromJson(value),
    ];
  }

  // ── Pending local-book bindings ─────────────────────────────────────────

  Future<void> putPending(AiPendingBinding binding) async {
    await _pending?.put(binding.id, binding.toJson());
  }

  Future<List<AiPendingBinding>> pendingBindings() async {
    if (!_available) return const [];
    return [
      for (final value in _pending?.values ?? const [])
        ?AiPendingBinding.fromJson(value),
    ];
  }

  Future<void> deletePending(String id) async {
    await _pending?.delete(id);
  }

  /// Device-only retention: request/run rows older than 180 days and raw trial
  /// edits beyond the latest five per book. Feedback, protections, prompts and
  /// formal cache are never pruned here.
  Future<void> prune({DateTime? now}) async {
    if (!_available) return;
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 180));
    for (final box in [_runs, _requests]) {
      if (box == null) continue;
      final doomed = <dynamic>[];
      for (final key in box.keys) {
        final value = box.get(key);
        final map = value is Map ? value : const {};
        final date = _date(map['startedAt']);
        if (date != null && date.isBefore(cutoff)) doomed.add(key);
      }
      if (doomed.isNotEmpty) await box.deleteAll(doomed);
    }
    final results = await trialResults();
    final byBook = <String, List<AiTrialResultRecord>>{};
    for (final result in results) {
      final trial = (await trials()).where((t) => t.trialId == result.trialId);
      final bookId = trial.isEmpty ? '' : trial.first.bookId;
      byBook.putIfAbsent(bookId, () => []).add(result);
    }
    for (final entry in byBook.entries) {
      entry.value.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      for (final old in entry.value.skip(5)) {
        await _trialResults?.delete(jsonEncode([old.trialId, old.chapterId]));
      }
    }
  }

  static DateTime? _date(Object? value) {
    if (value is int && value > 0) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    return null;
  }
}
