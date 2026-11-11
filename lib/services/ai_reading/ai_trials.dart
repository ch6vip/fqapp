import 'dart:convert';

import '../chapter_text_formatter.dart';
import '../chapter_cache_store.dart';
import 'ai_chapter_snapshot.dart';
import 'ai_coordinator.dart';
import 'ai_models.dart';
import 'ai_store.dart';
import 'ai_protocol.dart';
import 'ai_settings.dart';

class AiTrialChapter {
  const AiTrialChapter({
    required this.chapterId,
    required this.title,
    required this.content,
  });

  final String chapterId;
  final String title;
  final ChapterContent content;
}

class AiTrialNeedsBudget implements Exception {
  const AiTrialNeedsBudget(this.message);
  final String message;
}

class AiTrialService {
  AiTrialService({
    AiStore? store,
    AiCoordinator? coordinator,
    AiSettingsStore? settings,
  }) : _store = store ?? AiStore.instance,
       _settings = settings ?? AiSettingsStore.instance,
       _coordinator = coordinator ?? AiCoordinator.instance;

  static final instance = AiTrialService();
  final AiStore _store;
  final AiCoordinator _coordinator;
  final AiSettingsStore _settings;

  Future<AiTrialRecord> run({
    required String bookId,
    required String candidatePrompt,
    required List<AiTrialChapter> chapters,
    required List<AiFeedbackCase> feedbackCases,
    bool confirmedOverBudget = false,
  }) async {
    final effective = _settings.resolve(bookId);
    final restoreCensoredWords = effective.global.restoreCensoredWords;
    final now = DateTime.now();
    final trialId = 'trial_${now.microsecondsSinceEpoch.toRadixString(36)}';
    final feedbackRevisions = {
      for (final feedback in feedbackCases)
        feedback.feedbackId: feedback.caseRevision,
    };
    final snapshots = <String, AiChapterSnapshot>{};
    for (final chapter in chapters) {
      final snapshot = AiChapterSnapshotBuilder.fromContent(
        chapter.content,
        chapter.title,
      );
      snapshots['${chapter.chapterId}\u0000${snapshot.canonicalHash}'] =
          snapshot;
    }
    final trial = AiTrialRecord(
      trialId: trialId,
      bookId: bookId,
      candidateHash: _hash(candidatePrompt),
      configSnapshotHash: _hash(
        jsonEncode({
          'prompt': candidatePrompt,
          'provider': effective.providerId,
          'model': effective.modelId,
          'restoreCensoredWords': restoreCensoredWords,
        }),
      ),
      feedbackSnapshotHash: _hash(jsonEncode(feedbackRevisions)),
      feedbackCaseRevisions: feedbackRevisions,
      chapterHashes: snapshots.values.map((s) => s.canonicalHash).toList(),
      startedAt: now,
      state: 'running',
    );
    await _store.putTrial(trial);
    var anySuccess = false;
    var anyFailure = false;
    try {
      // Request the same content hash once, but evaluate feedback per chapter:
      // protection and feedback are chapter-scoped even when text is identical.
      final resultsByHash = <String, AiTaskResult>{};
      for (final chapter in chapters) {
        final snapshot = AiChapterSnapshotBuilder.fromContent(
          chapter.content,
          chapter.title,
        );
        var result = resultsByHash[snapshot.canonicalHash];
        if (result == null) {
          result = await _coordinator.runFormal(
            bookId: bookId,
            chapterId: chapter.chapterId,
            chapterTitle: chapter.title,
            content: chapter.content,
            kind: AiRunKind.trial,
            automatic: false,
            confirmedOverBudget: confirmedOverBudget,
            behaviorPromptOverride: candidatePrompt,
            restoreCensoredWords: restoreCensoredWords,
          );
          if (result.needsBudgetConfirmation) {
            throw AiTrialNeedsBudget(result.budgetMessage ?? '本次试验将超出预算');
          }
          resultsByHash[snapshot.canonicalHash] = result;
        }
        if (result.ok && result.validation != null) {
          anySuccess = true;
          final verdicts = _evaluate(
            snapshot: snapshot,
            validation: result.validation!,
            feedbackCases: feedbackCases.where(
              (f) =>
                  f.chapterId == chapter.chapterId &&
                  f.canonicalHash == snapshot.canonicalHash,
            ),
          );
          await _store.putTrialResult(
            AiTrialResultRecord(
              trialId: trialId,
              chapterId: chapter.chapterId,
              canonicalHash: snapshot.canonicalHash,
              runId: result.runId,
              rawValidatedEdits: result.validation!.edits,
              validationStatus: 'valid',
              perFeedback: verdicts,
              createdAt: DateTime.now(),
            ),
          );
        } else {
          anyFailure = true;
          await _store.putTrialResult(
            AiTrialResultRecord(
              trialId: trialId,
              chapterId: chapter.chapterId,
              canonicalHash: snapshot.canonicalHash,
              runId: result.runId,
              rawValidatedEdits: null,
              validationStatus: result.error ?? 'failed',
              perFeedback: const [],
              createdAt: DateTime.now(),
            ),
          );
        }
      }
    } catch (_) {
      await _store.putTrial(
        AiTrialRecord(
          trialId: trial.trialId,
          bookId: trial.bookId,
          candidateHash: trial.candidateHash,
          configSnapshotHash: trial.configSnapshotHash,
          feedbackSnapshotHash: trial.feedbackSnapshotHash,
          feedbackCaseRevisions: trial.feedbackCaseRevisions,
          chapterHashes: trial.chapterHashes,
          startedAt: trial.startedAt,
          state: 'failed',
        ),
      );
      rethrow;
    }
    final finished = AiTrialRecord(
      trialId: trial.trialId,
      bookId: trial.bookId,
      candidateHash: trial.candidateHash,
      configSnapshotHash: trial.configSnapshotHash,
      feedbackSnapshotHash: trial.feedbackSnapshotHash,
      feedbackCaseRevisions: trial.feedbackCaseRevisions,
      chapterHashes: trial.chapterHashes,
      startedAt: trial.startedAt,
      state: anyFailure ? (anySuccess ? 'partial' : 'failed') : 'completed',
    );
    await _store.putTrial(finished);
    return finished;
  }

  /// Recomputes verdicts from stored raw edits without sending a request.
  /// Only results whose chapter text is still cached with the same hash can be
  /// rescored; missing raw edits or changed text are reported as skipped.
  Future<({int rescored, int skipped})> rescore({
    required String bookId,
    required String trialId,
    required List<AiFeedbackCase> feedbackCases,
  }) async {
    final cache = ChapterCacheStore.instance;
    CachedBook? book;
    try {
      book =
          await cache.cachedBook(bookId) ?? await cache.savedCatalogue(bookId);
    } catch (_) {
      book = null;
    }
    final titles = <String, String>{
      for (final chapter in book?.chapters ?? const [])
        chapter.itemId: chapter.title,
    };
    final results = await _store.trialResults(trialId);
    var rescored = 0;
    var skipped = 0;
    const validator = AiValidator();
    for (final result in results) {
      final raw = result.rawValidatedEdits;
      final title = titles[result.chapterId];
      if (raw == null || title == null || title.isEmpty) {
        skipped++;
        continue;
      }
      try {
        final text = await cache.read(
          bookId: bookId,
          chapterId: result.chapterId,
        );
        if (text == null || text.trim().isEmpty) {
          skipped++;
          continue;
        }
        final snapshot = AiChapterSnapshotBuilder.fromContent(
          ChapterContent.fromCacheText(text),
          title,
        );
        if (snapshot.canonicalHash != result.canonicalHash) {
          skipped++;
          continue;
        }
        final validation = validator.validateContent(
          jsonEncode({'edits': raw.map((e) => e.toJson()).toList()}),
          snapshot,
        );
        if (!validation.valid) {
          skipped++;
          continue;
        }
        final verdicts = _evaluate(
          snapshot: snapshot,
          validation: validation,
          feedbackCases: feedbackCases.where(
            (f) =>
                f.chapterId == result.chapterId &&
                f.canonicalHash == snapshot.canonicalHash,
          ),
        );
        await _store.putTrialResult(
          AiTrialResultRecord(
            trialId: result.trialId,
            chapterId: result.chapterId,
            canonicalHash: result.canonicalHash,
            runId: result.runId,
            rawValidatedEdits: raw,
            validationStatus: 'valid',
            perFeedback: verdicts,
            createdAt: DateTime.now(),
          ),
        );
        rescored++;
      } catch (_) {
        skipped++;
      }
    }
    return (rescored: rescored, skipped: skipped);
  }

  List<AiTrialFeedbackVerdict> _evaluate({
    required AiChapterSnapshot snapshot,
    required AiValidationResult validation,
    required Iterable<AiFeedbackCase> feedbackCases,
  }) {
    final spans = validation.spans;
    final verdicts = <AiTrialFeedbackVerdict>[];
    for (final feedback in feedbackCases) {
      final anchorStart = feedback.anchor.sourceStart;
      final anchorEnd = feedback.anchor.sourceEnd;
      final intersecting = spans
          .where(
            (span) =>
                span.sourceStart < anchorEnd && anchorStart < span.sourceEnd,
          )
          .toList();
      final exact = spans
          .where(
            (span) =>
                span.sourceStart == anchorStart && span.sourceEnd == anchorEnd,
          )
          .toList();
      AiTrialVerdict verdict;
      final reasons = <String>[];
      switch (feedback.kind) {
        case AiFeedbackKind.good:
          final expected =
              feedback.assertion.expectedText ??
              (feedback.originalObservation?['replacement'] is String
                  ? feedback.originalObservation!['replacement'] as String
                  : null);
          if (expected == null) {
            verdict = AiTrialVerdict.cannotJudge;
            reasons.add('no_expected_text');
          } else if (exact.any((s) => s.replacement == expected)) {
            verdict = AiTrialVerdict.passed;
          } else if (exact.isNotEmpty || intersecting.isNotEmpty) {
            verdict = AiTrialVerdict.needsReview;
            reasons.add('different_replacement');
          } else {
            verdict = AiTrialVerdict.failed;
            reasons.add('approved_edit_missing');
          }
          break;
        case AiFeedbackKind.shouldNotChange:
          verdict = intersecting.isEmpty
              ? AiTrialVerdict.passed
              : AiTrialVerdict.failed;
          if (intersecting.isNotEmpty) reasons.add('protected_range_edited');
          break;
        case AiFeedbackKind.wrongChange:
          final expected = feedback.assertion.expectedText;
          final forbidden = feedback.assertion.forbiddenReplacement;
          if (expected != null &&
              intersecting.any((s) => s.replacement == expected)) {
            verdict = AiTrialVerdict.passed;
          } else if (forbidden != null &&
              intersecting.any((s) => s.replacement == forbidden)) {
            verdict = AiTrialVerdict.failed;
            reasons.add('old_wrong_replacement_repeated');
          } else if (intersecting.isNotEmpty) {
            verdict = AiTrialVerdict.needsReview;
            reasons.add('unknown_replacement');
          } else {
            verdict = AiTrialVerdict.needsReview;
            reasons.add('no_change');
          }
          break;
        case AiFeedbackKind.missedChange:
          final expected = feedback.assertion.expectedText;
          if (expected != null &&
              intersecting.any((s) => s.replacement == expected)) {
            verdict = AiTrialVerdict.passed;
          } else if (intersecting.isEmpty) {
            verdict = AiTrialVerdict.failed;
            reasons.add('still_missing');
          } else {
            verdict = AiTrialVerdict.needsReview;
            reasons.add('change_without_expected_text');
          }
          break;
      }
      verdicts.add(
        AiTrialFeedbackVerdict(
          feedbackId: feedback.feedbackId,
          revision: feedback.caseRevision,
          verdict: verdict,
          reasonCodes: reasons,
        ),
      );
    }
    return verdicts;
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
