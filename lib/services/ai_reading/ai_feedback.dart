import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ai_models.dart';
import 'ai_store.dart';

class AiFeedbackConflict implements Exception {
  const AiFeedbackConflict(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Book-level feedback cases and the two persistent display protections.
///
/// All writes for one chapter go through [AiStore.mutateAggregate], so a case
/// and its protection can never be half-written.
class AiFeedbackService extends ChangeNotifier {
  AiFeedbackService({AiStore? store}) : _store = store ?? AiStore.instance;

  static final instance = AiFeedbackService();
  final AiStore _store;

  Future<AiFeedbackAggregate?> aggregateForChapter({
    required String bookId,
    required String chapterId,
    required int canonicalVersion,
    required String canonicalHash,
  }) => _store.aggregate(
    bookId: bookId,
    chapterId: chapterId,
    canonicalVersion: canonicalVersion,
    canonicalHash: canonicalHash,
  );

  Future<List<AiFeedbackCase>> casesForBook(String bookId) async {
    final aggregates = await _store.allAggregates();
    return [
      for (final aggregate in aggregates)
        if (aggregate.bookId == bookId)
          for (final feedback in aggregate.cases) feedback,
    ];
  }

  /// Re-points a pending aggregate at a freshly imported local book. The
  /// canonical hash and every source offset stay unchanged; only the book and
  /// chapter ids move. Callers must verify the target snapshot first.
  static AiFeedbackAggregate rebindAggregate({
    required AiFeedbackAggregate aggregate,
    required String bookId,
    required String chapterId,
  }) {
    AiFeedbackCase rebindCase(AiFeedbackCase source) => AiFeedbackCase(
      feedbackId: source.feedbackId,
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: source.canonicalVersion,
      canonicalHash: source.canonicalHash,
      anchor: source.anchor,
      kind: source.kind,
      assertion: source.assertion,
      comment: source.comment,
      caseRevision: source.caseRevision,
      history: source.history,
      status: source.status,
      protectionEnabled: source.protectionEnabled,
      createdAt: source.createdAt,
      updatedAt: source.updatedAt,
      originalObservation: source.originalObservation,
    );

    AiFeedbackProtection rebindProtection(AiFeedbackProtection source) =>
        AiFeedbackProtection(
          protectionId: source.protectionId,
          sourceFeedbackId: source.sourceFeedbackId,
          sourceFeedbackRevision: source.sourceFeedbackRevision,
          bookId: bookId,
          chapterId: chapterId,
          canonicalVersion: source.canonicalVersion,
          canonicalHash: source.canonicalHash,
          sourceStart: source.sourceStart,
          sourceEnd: source.sourceEnd,
          sourceText: source.sourceText,
          paragraphIndex: source.paragraphIndex,
          policy: source.policy,
          status: source.status,
          createdAt: source.createdAt,
          updatedAt: source.updatedAt,
          approvedEdit: source.approvedEdit,
          supersededByFeedbackId: source.supersededByFeedbackId,
        );

    return AiFeedbackAggregate(
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: aggregate.canonicalVersion,
      canonicalHash: aggregate.canonicalHash,
      aggregateRevision: aggregate.aggregateRevision,
      cases: aggregate.cases.map(rebindCase).toList(),
      protections: aggregate.protections.map(rebindProtection).toList(),
      updatedAt: DateTime.now(),
    );
  }

  /// True when the aggregate belongs to [snapshot] and every stored source
  /// offset still points at the exact text it was created from.
  static bool aggregateFitsSnapshot(
    AiFeedbackAggregate aggregate,
    AiChapterSnapshot snapshot,
  ) {
    if (aggregate.canonicalVersion != snapshot.canonicalVersion ||
        aggregate.canonicalHash != snapshot.canonicalHash) {
      return false;
    }
    bool fits(int start, int end, String text, int paragraphIndex) {
      if (start < 0 ||
          end < start ||
          end > snapshot.requestText.length ||
          paragraphIndex < 0 ||
          paragraphIndex >= snapshot.paragraphs.length) {
        return false;
      }
      return snapshot.requestText.substring(start, end) == text;
    }

    for (final feedback in aggregate.cases) {
      if (!fits(
        feedback.anchor.sourceStart,
        feedback.anchor.sourceEnd,
        feedback.anchor.sourceText,
        feedback.anchor.paragraphIndex,
      )) {
        return false;
      }
      final start = feedback.assertion.assertionAnchorStart;
      final end = feedback.assertion.assertionAnchorEnd;
      if (start != null &&
          end != null &&
          (start < 0 || end < start || end > snapshot.requestText.length)) {
        return false;
      }
    }
    for (final protection in aggregate.protections) {
      if (!fits(
        protection.sourceStart,
        protection.sourceEnd,
        protection.sourceText,
        protection.paragraphIndex,
      )) {
        return false;
      }
      final edit = protection.approvedEdit;
      if (edit != null &&
          !fits(
            edit.sourceStart,
            edit.sourceEnd,
            edit.original,
            edit.paragraphIndex,
          )) {
        return false;
      }
    }
    return true;
  }

  /// Re-anchors one feedback case onto the current chapter version. The user
  /// must select a non-empty, single-paragraph source range. The old aggregate
  /// is removed and the new one is written under the current hash; the case
  /// revision and revision history are preserved.
  Future<AiFeedbackCase> reanchorCase({
    required AiFeedbackCase feedback,
    required AiChapterSnapshot snapshot,
    required int sourceStart,
    required int sourceEnd,
  }) async {
    if (sourceEnd <= sourceStart ||
        sourceStart < 0 ||
        sourceEnd > snapshot.requestText.length) {
      throw const AiFeedbackConflict('重新定位的区间无效');
    }
    final paragraph = snapshot.paragraphIndexAt(sourceStart);
    if (paragraph == null || sourceEnd > snapshot.paragraphEnd(paragraph)) {
      throw const AiFeedbackConflict('重新定位只能落在单个段落内');
    }
    final sourceText = snapshot.requestText.substring(sourceStart, sourceEnd);
    final now = DateTime.now();
    final revision = feedback.caseRevision + 1;
    final assertion = AiFeedbackAssertion(
      type: feedback.assertion.type,
      expectedText: feedback.assertion.expectedText,
      forbiddenReplacement: feedback.assertion.forbiddenReplacement,
      assertionAnchorStart: sourceStart,
      assertionAnchorEnd: sourceEnd,
    );
    final observation = feedback.originalObservation == null
        ? null
        : {...feedback.originalObservation!, 'original': sourceText};
    final updated = AiFeedbackCase(
      feedbackId: feedback.feedbackId,
      bookId: feedback.bookId,
      chapterId: feedback.chapterId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      anchor: AiSourceAnchor(
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        paragraphIndex: paragraph,
        sourceText: sourceText,
      ),
      kind: feedback.kind,
      assertion: assertion,
      comment: feedback.comment,
      caseRevision: revision,
      history: [
        ...feedback.history,
        AiFeedbackHistoryEntry(
          revision: revision,
          kind: feedback.kind,
          assertion: assertion,
          comment: feedback.comment,
          status: feedback.status,
          changedAt: now,
        ),
      ],
      status: feedback.status,
      protectionEnabled: feedback.protectionEnabled,
      createdAt: feedback.createdAt,
      updatedAt: now,
      originalObservation: observation,
    );
    final protection = _protectionFromExisting(feedback: updated, now: now);

    // Check the destination before touching the old aggregate.
    final destination = await _store.aggregate(
      bookId: feedback.bookId,
      chapterId: feedback.chapterId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
    );
    if (protection != null && destination != null) {
      final overlap = destination.protections.where(
        (p) =>
            p.isActive &&
            p.sourceFeedbackId != feedback.feedbackId &&
            p.intersects(protection.sourceStart, protection.sourceEnd),
      );
      if (overlap.isNotEmpty) {
        throw const AiFeedbackConflict('新位置与已有保护重叠，请先处理冲突');
      }
    }

    final sameAggregate =
        feedback.canonicalHash == snapshot.canonicalHash &&
        feedback.canonicalVersion == snapshot.canonicalVersion;
    if (!sameAggregate) {
      await _store.mutateAggregate(
        bookId: feedback.bookId,
        chapterId: feedback.chapterId,
        canonicalVersion: feedback.canonicalVersion,
        canonicalHash: feedback.canonicalHash,
        mutate: (current) => _aggregate(
          current,
          bookId: feedback.bookId,
          chapterId: feedback.chapterId,
          canonicalVersion: feedback.canonicalVersion,
          canonicalHash: feedback.canonicalHash,
          cases: [
            for (final c in current?.cases ?? const <AiFeedbackCase>[])
              if (c.feedbackId != feedback.feedbackId) c,
          ],
          protections: [
            for (final p
                in current?.protections ?? const <AiFeedbackProtection>[])
              if (p.sourceFeedbackId != feedback.feedbackId) p,
          ],
        ),
      );
    }

    await _store.mutateAggregate(
      bookId: feedback.bookId,
      chapterId: feedback.chapterId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      mutate: (current) => _aggregate(
        current,
        bookId: feedback.bookId,
        chapterId: feedback.chapterId,
        canonicalVersion: snapshot.canonicalVersion,
        canonicalHash: snapshot.canonicalHash,
        cases: [
          for (final c in current?.cases ?? const <AiFeedbackCase>[])
            if (c.feedbackId != feedback.feedbackId) c,
          updated,
        ],
        protections: [
          for (final p
              in current?.protections ?? const <AiFeedbackProtection>[])
            if (p.sourceFeedbackId != feedback.feedbackId) p,
          ?protection,
        ],
      ),
    );
    notifyListeners();
    return updated;
  }

  Future<List<AiFeedbackAggregate>> aggregatesForBook(String bookId) async {
    final aggregates = await _store.allAggregates();
    return [
      for (final aggregate in aggregates)
        if (aggregate.bookId == bookId) aggregate,
    ];
  }

  Future<List<AiFeedbackProtection>> activeProtections({
    required String bookId,
    required String chapterId,
    required int canonicalVersion,
    required String canonicalHash,
  }) async {
    final aggregate = await aggregateForChapter(
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: canonicalVersion,
      canonicalHash: canonicalHash,
    );
    return aggregate?.activeProtections ?? const [];
  }

  Future<AiFeedbackCase> addFromEdit({
    required String bookId,
    required String chapterId,
    required AiChapterSnapshot snapshot,
    required AiEditSpan span,
    required AiFeedbackKind kind,
    String comment = '',
    String? expectedText,
    String? sourceRunId,
    bool supersedeOverlappingGood = false,
  }) async {
    if (kind == AiFeedbackKind.missedChange) {
      throw const AiFeedbackConflict('漏改了必须从选区创建');
    }
    final anchor = AiSourceAnchor(
      sourceStart: span.sourceStart,
      sourceEnd: span.sourceEnd,
      paragraphIndex: span.paragraphIndex,
      sourceText: span.original,
    );
    final assertion = _assertionForEdit(kind, span, expectedText);
    final now = DateTime.now();
    final feedback = AiFeedbackCase(
      feedbackId: _newId('fb'),
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      anchor: anchor,
      kind: kind,
      assertion: assertion,
      comment: comment,
      caseRevision: 1,
      history: [
        AiFeedbackHistoryEntry(
          revision: 1,
          kind: kind,
          assertion: assertion,
          comment: comment,
          status: AiFeedbackStatus.active,
          changedAt: now,
        ),
      ],
      status: AiFeedbackStatus.active,
      protectionEnabled:
          kind == AiFeedbackKind.good || kind == AiFeedbackKind.shouldNotChange,
      createdAt: now,
      updatedAt: now,
      originalObservation: {
        'sourceRunId': ?sourceRunId,
        'sourceEditIndex': span.editIndex,
        'original': span.original,
        'replacement': span.replacement,
        'category': span.category,
        'reason': span.reason,
      },
    );
    final protection = _protectionFor(
      feedback: feedback,
      span: span,
      snapshot: snapshot,
      now: now,
    );

    return _mutate(
      snapshot: snapshot,
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      mutate: (current) {
        var cases = [...?current?.cases];
        var protections = [...?current?.protections];
        if (protection != null) {
          final overlaps = protections
              .where(
                (p) =>
                    p.isActive &&
                    p.intersects(protection.sourceStart, protection.sourceEnd),
              )
              .toList();
          if (overlaps.isNotEmpty) {
            if (kind == AiFeedbackKind.good &&
                supersedeOverlappingGood &&
                overlaps.every((p) => p.isKeepApproved)) {
              final ids = overlaps.map((p) => p.sourceFeedbackId).toSet();
              protections = [
                for (final p in protections)
                  if (ids.contains(p.sourceFeedbackId) && p.isActive)
                    p.copyWith(
                      status: AiProtectionStatus.superseded,
                      supersededByFeedbackId: feedback.feedbackId,
                      updatedAt: now,
                    )
                  else
                    p,
              ];
              cases = [
                for (final c in cases)
                  if (ids.contains(c.feedbackId) && c.isActive)
                    c.copyWith(
                      status: AiFeedbackStatus.superseded,
                      updatedAt: now,
                    )
                  else
                    c,
              ];
            } else {
              throw AiFeedbackConflict(
                kind == AiFeedbackKind.good
                    ? '此处已有生效保护，需要确认替代旧改法'
                    : '此处已有生效保护，请先处理冲突',
              );
            }
          }
        }
        cases.add(feedback);
        if (protection != null) protections.add(protection);
        return _aggregate(
          current,
          bookId: bookId,
          chapterId: chapterId,
          canonicalVersion: snapshot.canonicalVersion,
          canonicalHash: snapshot.canonicalHash,
          cases: cases,
          protections: protections,
        );
      },
    ).then(
      (aggregate) => aggregate.cases.firstWhere(
        (c) => c.feedbackId == feedback.feedbackId,
      ),
    );
  }

  Future<AiFeedbackCase> addMissedSelection({
    required String bookId,
    required String chapterId,
    required AiChapterSnapshot snapshot,
    required int sourceStart,
    required int sourceEnd,
    String comment = '',
    String? expectedText,
  }) async {
    if (sourceStart < 0 ||
        sourceEnd <= sourceStart ||
        sourceEnd > snapshot.requestText.length) {
      throw const AiFeedbackConflict('选区超出本章正文');
    }
    final paragraph = snapshot.paragraphIndexAt(sourceStart);
    if (paragraph == null || sourceEnd > snapshot.paragraphEnd(paragraph)) {
      throw const AiFeedbackConflict('漏改了只能标在单个段落内');
    }
    final sourceText = snapshot.requestText.substring(sourceStart, sourceEnd);
    final assertion = expectedText == null || expectedText.trim().isEmpty
        ? AiFeedbackAssertion(
            type: 'manual_review',
            assertionAnchorStart: sourceStart,
            assertionAnchorEnd: sourceEnd,
          )
        : AiFeedbackAssertion(
            type: 'must_equal',
            expectedText: expectedText,
            assertionAnchorStart: sourceStart,
            assertionAnchorEnd: sourceEnd,
          );
    final now = DateTime.now();
    final feedback = AiFeedbackCase(
      feedbackId: _newId('fb'),
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      anchor: AiSourceAnchor(
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        paragraphIndex: paragraph,
        sourceText: sourceText,
      ),
      kind: AiFeedbackKind.missedChange,
      assertion: assertion,
      comment: comment,
      caseRevision: 1,
      history: [
        AiFeedbackHistoryEntry(
          revision: 1,
          kind: AiFeedbackKind.missedChange,
          assertion: assertion,
          comment: comment,
          status: AiFeedbackStatus.active,
          changedAt: now,
        ),
      ],
      status: AiFeedbackStatus.active,
      protectionEnabled: false,
      createdAt: now,
      updatedAt: now,
    );
    return _mutate(
      snapshot: snapshot,
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      mutate: (current) => _aggregate(
        current,
        bookId: bookId,
        chapterId: chapterId,
        canonicalVersion: snapshot.canonicalVersion,
        canonicalHash: snapshot.canonicalHash,
        cases: [...?current?.cases, feedback],
        protections: [...?current?.protections],
      ),
    ).then(
      (aggregate) => aggregate.cases.firstWhere(
        (c) => c.feedbackId == feedback.feedbackId,
      ),
    );
  }

  Future<AiFeedbackCase> updateCase({
    required AiFeedbackCase currentCase,
    required AiChapterSnapshot snapshot,
    AiFeedbackKind? kind,
    String? comment,
    String? expectedText,
    bool? protectionEnabled,
  }) async {
    final nextKind = kind ?? currentCase.kind;
    final nextComment = comment ?? currentCase.comment;
    final nextProtection = protectionEnabled ?? currentCase.protectionEnabled;
    final assertion = _assertionForUpdate(
      currentCase,
      nextKind,
      expectedText: expectedText,
    );
    if (nextKind == AiFeedbackKind.good &&
        currentCase.originalObservation == null) {
      throw const AiFeedbackConflict('改得好必须来自已验证的 AI 修改');
    }
    final now = DateTime.now();
    final revision = currentCase.caseRevision + 1;
    final updated = currentCase.copyWith(
      kind: nextKind,
      assertion: assertion,
      comment: nextComment,
      caseRevision: revision,
      protectionEnabled: nextProtection,
      updatedAt: now,
      history: [
        ...currentCase.history,
        AiFeedbackHistoryEntry(
          revision: revision,
          kind: nextKind,
          assertion: assertion,
          comment: nextComment,
          status: currentCase.status,
          changedAt: now,
        ),
      ],
    );
    return _mutate(
      snapshot: snapshot,
      bookId: currentCase.bookId,
      chapterId: currentCase.chapterId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      mutate: (current) {
        var cases = [...?current?.cases];
        var protections = [...?current?.protections];
        cases = [
          for (final c in cases)
            if (c.feedbackId == currentCase.feedbackId) updated else c,
        ];
        // Revoke the old derived protection, then optionally create the new one.
        protections = [
          for (final p in protections)
            if (p.sourceFeedbackId == currentCase.feedbackId && p.isActive)
              p.copyWith(status: AiProtectionStatus.revoked, updatedAt: now)
            else
              p,
        ];
        if (currentCase.status == AiFeedbackStatus.active &&
            nextProtection &&
            (nextKind == AiFeedbackKind.good ||
                nextKind == AiFeedbackKind.shouldNotChange)) {
          final protection = _protectionFromExisting(
            feedback: updated,
            now: now,
          );
          if (protection == null) {
            throw const AiFeedbackConflict('这条反馈没有可用的原文锚点');
          }
          final overlap = protections.where(
            (p) =>
                p.isActive &&
                p.sourceFeedbackId != currentCase.feedbackId &&
                p.intersects(protection.sourceStart, protection.sourceEnd),
          );
          if (overlap.isNotEmpty) {
            throw const AiFeedbackConflict('新保护与其他生效保护重叠');
          }
          protections.add(protection);
        }
        return _aggregate(
          current,
          bookId: currentCase.bookId,
          chapterId: currentCase.chapterId,
          canonicalVersion: snapshot.canonicalVersion,
          canonicalHash: snapshot.canonicalHash,
          cases: cases,
          protections: protections,
        );
      },
    ).then(
      (aggregate) => aggregate.cases.firstWhere(
        (c) => c.feedbackId == currentCase.feedbackId,
      ),
    );
  }

  Future<void> setStatus({
    required AiFeedbackCase feedback,
    required AiFeedbackStatus status,
  }) async {
    final now = DateTime.now();
    await _mutate(
      snapshot: null,
      bookId: feedback.bookId,
      chapterId: feedback.chapterId,
      canonicalVersion: feedback.canonicalVersion,
      canonicalHash: feedback.canonicalHash,
      mutate: (current) {
        final cases = [
          for (final c in current?.cases ?? const <AiFeedbackCase>[])
            if (c.feedbackId == feedback.feedbackId)
              c.copyWith(status: status, updatedAt: now)
            else
              c,
        ];
        var protections = [
          for (final p
              in current?.protections ?? const <AiFeedbackProtection>[])
            if (p.sourceFeedbackId == feedback.feedbackId &&
                (status == AiFeedbackStatus.archived ||
                    status == AiFeedbackStatus.superseded ||
                    status == AiFeedbackStatus.deleted))
              p.copyWith(status: AiProtectionStatus.revoked, updatedAt: now)
            else
              p,
        ];
        if (status == AiFeedbackStatus.active &&
            feedback.protectionEnabled &&
            (feedback.kind == AiFeedbackKind.good ||
                feedback.kind == AiFeedbackKind.shouldNotChange) &&
            !protections.any(
              (p) => p.sourceFeedbackId == feedback.feedbackId && p.isActive,
            )) {
          final updated = cases.firstWhere(
            (c) => c.feedbackId == feedback.feedbackId,
          );
          final protection = _protectionFromExisting(
            feedback: updated,
            now: now,
          );
          if (protection != null) {
            final overlap = protections.where(
              (p) =>
                  p.isActive &&
                  p.sourceFeedbackId != feedback.feedbackId &&
                  p.intersects(protection.sourceStart, protection.sourceEnd),
            );
            if (overlap.isNotEmpty) {
              throw const AiFeedbackConflict('恢复保护与其他生效保护重叠');
            }
            protections.add(protection);
          }
        }
        return AiFeedbackAggregate(
          bookId: feedback.bookId,
          chapterId: feedback.chapterId,
          canonicalVersion: feedback.canonicalVersion,
          canonicalHash: feedback.canonicalHash,
          aggregateRevision: current?.aggregateRevision ?? 0,
          cases: cases,
          protections: protections,
          updatedAt: now,
        );
      },
    );
  }

  Future<void> setProtectionEnabled({
    required AiFeedbackCase feedback,
    required bool enabled,
  }) async {
    final now = DateTime.now();
    await _mutate(
      snapshot: null,
      bookId: feedback.bookId,
      chapterId: feedback.chapterId,
      canonicalVersion: feedback.canonicalVersion,
      canonicalHash: feedback.canonicalHash,
      mutate: (current) {
        var cases = [
          for (final c in current?.cases ?? const <AiFeedbackCase>[])
            if (c.feedbackId == feedback.feedbackId)
              c.copyWith(protectionEnabled: enabled, updatedAt: now)
            else
              c,
        ];
        var protections = [
          for (final p
              in current?.protections ?? const <AiFeedbackProtection>[])
            if (p.sourceFeedbackId == feedback.feedbackId &&
                p.isActive &&
                !enabled)
              p.copyWith(status: AiProtectionStatus.revoked, updatedAt: now)
            else
              p,
        ];
        if (enabled &&
            (feedback.kind == AiFeedbackKind.good ||
                feedback.kind == AiFeedbackKind.shouldNotChange)) {
          final existing = protections.where(
            (p) =>
                p.sourceFeedbackId == feedback.feedbackId &&
                p.status == AiProtectionStatus.active,
          );
          if (existing.isEmpty) {
            final updatedCase = cases.firstWhere(
              (c) => c.feedbackId == feedback.feedbackId,
            );
            final protection = _protectionFromExisting(
              feedback: updatedCase,
              now: now,
            );
            if (protection == null) {
              throw const AiFeedbackConflict('没有可恢复的保护锚点');
            }
            final overlap = protections.where(
              (p) =>
                  p.isActive &&
                  p.sourceFeedbackId != feedback.feedbackId &&
                  p.intersects(protection.sourceStart, protection.sourceEnd),
            );
            if (overlap.isNotEmpty) {
              throw const AiFeedbackConflict('保护区间与其他生效保护重叠');
            }
            protections.add(protection);
          }
        }
        return AiFeedbackAggregate(
          bookId: feedback.bookId,
          chapterId: feedback.chapterId,
          canonicalVersion: feedback.canonicalVersion,
          canonicalHash: feedback.canonicalHash,
          aggregateRevision: current?.aggregateRevision ?? 0,
          cases: cases,
          protections: protections,
          updatedAt: now,
        );
      },
    );
  }

  Future<void> deleteCase(
    AiFeedbackCase feedback, {
    bool permanent = false,
  }) async {
    if (!permanent) {
      await setStatus(feedback: feedback, status: AiFeedbackStatus.deleted);
      return;
    }
    final aggregate = await aggregateForChapter(
      bookId: feedback.bookId,
      chapterId: feedback.chapterId,
      canonicalVersion: feedback.canonicalVersion,
      canonicalHash: feedback.canonicalHash,
    );
    if (aggregate == null) return;
    final next = AiFeedbackAggregate(
      bookId: aggregate.bookId,
      chapterId: aggregate.chapterId,
      canonicalVersion: aggregate.canonicalVersion,
      canonicalHash: aggregate.canonicalHash,
      aggregateRevision: aggregate.aggregateRevision,
      cases: aggregate.cases
          .where((c) => c.feedbackId != feedback.feedbackId)
          .toList(),
      protections: aggregate.protections
          .where((p) => p.sourceFeedbackId != feedback.feedbackId)
          .toList(),
      updatedAt: DateTime.now(),
    );
    await _store.mutateAggregate(
      bookId: aggregate.bookId,
      chapterId: aggregate.chapterId,
      canonicalVersion: aggregate.canonicalVersion,
      canonicalHash: aggregate.canonicalHash,
      mutate: (_) => next,
    );
    notifyListeners();
  }

  Future<AiFeedbackAggregate> _mutate({
    required AiChapterSnapshot? snapshot,
    required String bookId,
    required String chapterId,
    required int canonicalVersion,
    required String canonicalHash,
    required AiFeedbackAggregate Function(AiFeedbackAggregate? current) mutate,
  }) async {
    final result = await _store.mutateAggregate(
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: canonicalVersion,
      canonicalHash: canonicalHash,
      mutate: mutate,
    );
    notifyListeners();
    return result;
  }

  AiFeedbackProtection? _protectionFor({
    required AiFeedbackCase feedback,
    required AiEditSpan span,
    required AiChapterSnapshot snapshot,
    required DateTime now,
  }) {
    if (feedback.kind == AiFeedbackKind.good) {
      return AiFeedbackProtection(
        protectionId: _newId('pr'),
        sourceFeedbackId: feedback.feedbackId,
        sourceFeedbackRevision: feedback.caseRevision,
        bookId: feedback.bookId,
        chapterId: feedback.chapterId,
        canonicalVersion: snapshot.canonicalVersion,
        canonicalHash: snapshot.canonicalHash,
        sourceStart: span.sourceStart,
        sourceEnd: span.sourceEnd,
        sourceText: span.original,
        paragraphIndex: span.paragraphIndex,
        policy: AiProtectionPolicy.keepApprovedEdit,
        status: AiProtectionStatus.active,
        approvedEdit: AiApprovedEdit(
          original: span.original,
          replacement: span.replacement,
          sourceStart: span.sourceStart,
          sourceEnd: span.sourceEnd,
          paragraphIndex: span.paragraphIndex,
          category: span.category,
          reason: span.reason,
          sourceEditIndex: span.editIndex,
        ),
        createdAt: now,
        updatedAt: now,
      );
    }
    if (feedback.kind == AiFeedbackKind.shouldNotChange) {
      return AiFeedbackProtection(
        protectionId: _newId('pr'),
        sourceFeedbackId: feedback.feedbackId,
        sourceFeedbackRevision: feedback.caseRevision,
        bookId: feedback.bookId,
        chapterId: feedback.chapterId,
        canonicalVersion: snapshot.canonicalVersion,
        canonicalHash: snapshot.canonicalHash,
        sourceStart: span.sourceStart,
        sourceEnd: span.sourceEnd,
        sourceText: span.original,
        paragraphIndex: span.paragraphIndex,
        policy: AiProtectionPolicy.keepOriginal,
        status: AiProtectionStatus.active,
        createdAt: now,
        updatedAt: now,
      );
    }
    return null;
  }

  AiFeedbackProtection? _protectionFromExisting({
    required AiFeedbackCase feedback,
    required DateTime now,
  }) {
    if (feedback.kind == AiFeedbackKind.shouldNotChange) {
      return AiFeedbackProtection(
        protectionId: _newId('pr'),
        sourceFeedbackId: feedback.feedbackId,
        sourceFeedbackRevision: feedback.caseRevision,
        bookId: feedback.bookId,
        chapterId: feedback.chapterId,
        canonicalVersion: feedback.canonicalVersion,
        canonicalHash: feedback.canonicalHash,
        sourceStart: feedback.anchor.sourceStart,
        sourceEnd: feedback.anchor.sourceEnd,
        sourceText: feedback.anchor.sourceText,
        paragraphIndex: feedback.anchor.paragraphIndex,
        policy: AiProtectionPolicy.keepOriginal,
        status: AiProtectionStatus.active,
        createdAt: now,
        updatedAt: now,
      );
    }
    if (feedback.kind != AiFeedbackKind.good) return null;
    final observation = feedback.originalObservation;
    if (observation == null) return null;
    final original = observation['original'];
    final replacement = observation['replacement'];
    if (original is! String || replacement is! String) return null;
    return AiFeedbackProtection(
      protectionId: _newId('pr'),
      sourceFeedbackId: feedback.feedbackId,
      sourceFeedbackRevision: feedback.caseRevision,
      bookId: feedback.bookId,
      chapterId: feedback.chapterId,
      canonicalVersion: feedback.canonicalVersion,
      canonicalHash: feedback.canonicalHash,
      sourceStart: feedback.anchor.sourceStart,
      sourceEnd: feedback.anchor.sourceEnd,
      sourceText: feedback.anchor.sourceText,
      paragraphIndex: feedback.anchor.paragraphIndex,
      policy: AiProtectionPolicy.keepApprovedEdit,
      status: AiProtectionStatus.active,
      approvedEdit: AiApprovedEdit(
        original: original,
        replacement: replacement,
        sourceStart: feedback.anchor.sourceStart,
        sourceEnd: feedback.anchor.sourceEnd,
        paragraphIndex: feedback.anchor.paragraphIndex,
        category: observation['category'] is String
            ? observation['category'] as String
            : null,
        reason: observation['reason'] is String
            ? observation['reason'] as String
            : null,
        sourceEditIndex: observation['sourceEditIndex'] is int
            ? observation['sourceEditIndex'] as int
            : null,
      ),
      createdAt: now,
      updatedAt: now,
    );
  }

  static AiFeedbackAssertion _assertionForEdit(
    AiFeedbackKind kind,
    AiEditSpan span,
    String? expectedText,
  ) {
    return switch (kind) {
      AiFeedbackKind.good => AiFeedbackAssertion(
        type: 'must_equal',
        expectedText: span.replacement,
        assertionAnchorStart: span.sourceStart,
        assertionAnchorEnd: span.sourceEnd,
      ),
      AiFeedbackKind.shouldNotChange => AiFeedbackAssertion(
        type: 'must_remain_original',
        assertionAnchorStart: span.sourceStart,
        assertionAnchorEnd: span.sourceEnd,
      ),
      AiFeedbackKind.wrongChange => AiFeedbackAssertion(
        type: expectedText == null || expectedText.trim().isEmpty
            ? 'must_not_equal'
            : 'must_equal',
        expectedText: expectedText,
        forbiddenReplacement: span.replacement,
        assertionAnchorStart: span.sourceStart,
        assertionAnchorEnd: span.sourceEnd,
      ),
      AiFeedbackKind.missedChange => AiFeedbackAssertion(
        type: expectedText == null || expectedText.trim().isEmpty
            ? 'manual_review'
            : 'must_equal',
        expectedText: expectedText,
        assertionAnchorStart: span.sourceStart,
        assertionAnchorEnd: span.sourceEnd,
      ),
    };
  }

  static AiFeedbackAssertion _assertionForUpdate(
    AiFeedbackCase feedback,
    AiFeedbackKind kind, {
    String? expectedText,
  }) {
    if (kind == AiFeedbackKind.shouldNotChange) {
      return AiFeedbackAssertion(
        type: 'must_remain_original',
        assertionAnchorStart: feedback.anchor.sourceStart,
        assertionAnchorEnd: feedback.anchor.sourceEnd,
      );
    }
    if (kind == AiFeedbackKind.good) {
      final observation = feedback.originalObservation;
      final replacement = observation?['replacement'];
      return AiFeedbackAssertion(
        type: 'must_equal',
        expectedText: replacement is String
            ? replacement
            : feedback.assertion.expectedText,
        assertionAnchorStart: feedback.anchor.sourceStart,
        assertionAnchorEnd: feedback.anchor.sourceEnd,
      );
    }
    return AiFeedbackAssertion(
      type: expectedText == null || expectedText.trim().isEmpty
          ? (kind == AiFeedbackKind.wrongChange
                ? 'must_not_equal'
                : 'manual_review')
          : 'must_equal',
      expectedText: expectedText ?? feedback.assertion.expectedText,
      forbiddenReplacement: feedback.assertion.forbiddenReplacement,
      assertionAnchorStart: feedback.anchor.sourceStart,
      assertionAnchorEnd: feedback.anchor.sourceEnd,
    );
  }

  static AiFeedbackAggregate _aggregate(
    AiFeedbackAggregate? current, {
    required String bookId,
    required String chapterId,
    required int canonicalVersion,
    required String canonicalHash,
    required List<AiFeedbackCase> cases,
    required List<AiFeedbackProtection> protections,
  }) => AiFeedbackAggregate(
    bookId: bookId,
    chapterId: chapterId,
    canonicalVersion: canonicalVersion,
    canonicalHash: canonicalHash,
    aggregateRevision: current?.aggregateRevision ?? 0,
    cases: cases,
    protections: protections,
    updatedAt: DateTime.now(),
  );

  static String _newId(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return '${prefix}_${base64Url.encode(bytes).replaceAll('=', '')}';
  }
}
