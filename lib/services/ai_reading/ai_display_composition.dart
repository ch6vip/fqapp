import 'dart:convert';

import '../chapter_text_formatter.dart';
import '../../models/text_replacement_rule.dart';
import '../text_replacement_engine.dart';
import 'ai_apply.dart';
import 'ai_feedback.dart';
import 'ai_models.dart';
import 'ai_protocol.dart';
import 'ai_store.dart';

/// Inputs that decide which display layer is visible. `aiRequestEnabled`
/// controls network/formal lookups; `displayMode` controls what the reader
/// shows. They are deliberately separate (an old custom replacement must keep
/// working when the AI switch is off).
class AiCompositionConfig {
  const AiCompositionConfig({
    required this.aiRequestEnabled,
    required this.displayMode,
    this.temporaryOriginal = false,
    this.previewSourceStart,
    this.previewSourceEnd,
  });

  final bool aiRequestEnabled;
  final AiDisplayMode displayMode;
  final bool temporaryOriginal;
  final int? previewSourceStart;
  final int? previewSourceEnd;

  bool previews(int start, int end) =>
      previewSourceStart != null &&
      previewSourceEnd != null &&
      start < previewSourceEnd! &&
      previewSourceStart! < end;

  AiDisplayMode get effectiveMode {
    if (temporaryOriginal) return AiDisplayMode.original;
    if (displayMode == AiDisplayMode.original) return AiDisplayMode.original;
    // Turning AI off must hide the AI layer and keep old custom replacement
    // rules working. Only an explicit "原文" mode disables both layers.
    if (!aiRequestEnabled) return AiDisplayMode.customOnly;
    return displayMode;
  }
}

class AiBlockedEdit {
  const AiBlockedEdit({
    required this.span,
    required this.protectionIds,
    required this.keepOriginal,
  });

  final AiEditSpan span;
  final List<String> protectionIds;
  final bool keepOriginal;
}

class AiCompositionResult {
  const AiCompositionResult({
    required this.replacement,
    required this.snapshot,
    required this.displayRevision,
    this.applied,
    this.formal,
    this.rawCount = 0,
    this.skippedByProtection = 0,
    this.approvedCount = 0,
    this.protections = const [],
    this.displaySpans = const [],
    this.blockedEdits = const [],
    this.error,
  });

  final TextReplacementResult replacement;
  final AiChapterSnapshot snapshot;
  final int displayRevision;
  final AiApplyResult? applied;
  final AiFormalCacheEntry? formal;
  final int rawCount;
  final int skippedByProtection;
  final int approvedCount;
  final List<AiFeedbackProtection> protections;

  /// Spans in final display coordinates, after custom replacement rules.
  /// [applied.spans] are relative to the AI-only content and must not be used
  /// for reader marks when a custom rule changes text before them.
  final List<AiEditSpan> displaySpans;
  final List<AiBlockedEdit> blockedEdits;
  final String? error;

  bool get hasAiLayer => applied != null;
  bool get isCached => formal != null;
}

/// Composes original -> protection filter/approved replay -> user replacement.
///
/// `TextReplacementResult.source` is always the immutable original content.
/// The custom replacement engine is run on the AI display content only to keep
/// its own rules after the AI layer; its map is then composed with the AI map.
class AiDisplayComposition {
  AiDisplayComposition({
    AiStore? store,
    AiFeedbackService? feedback,
    TextReplacementEngine? replacementEngine,
    AiValidator? validator,
  }) : _store = store ?? AiStore.instance,
       _feedback = feedback ?? AiFeedbackService.instance,
       _replacement = replacementEngine ?? TextReplacementEngine.instance,
       _validator = validator ?? const AiValidator();

  static final instance = AiDisplayComposition();
  final AiStore _store;
  final AiFeedbackService _feedback;
  final TextReplacementEngine _replacement;
  final AiValidator _validator;

  Future<AiCompositionResult> compose({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required ChapterContent content,
    required AiChapterSnapshot snapshot,
    required TextReplacementSnapshot customSnapshot,
    required AiCompositionConfig config,
    TextReplacementEngine? replacementEngine,
  }) async {
    final engine = replacementEngine ?? _replacement;
    final mode = config.effectiveMode;
    final formal = await _store.formal(bookId, snapshot.canonicalHash);
    if (mode == AiDisplayMode.original) {
      final identity = TextReplacementResult(
        source: content,
        content: content,
        snapshotRevision: customSnapshot.revision,
      );
      return AiCompositionResult(
        replacement: identity,
        snapshot: snapshot,
        displayRevision: _revision(
          mode,
          formal,
          null,
          customSnapshot.revision,
          config.temporaryOriginal,
        ),
        formal: formal,
      );
    }

    if (mode == AiDisplayMode.customOnly) {
      final custom = await engine.transform(
        source: content,
        chapterTitle: chapterTitle,
        snapshot: customSnapshot,
      );
      return AiCompositionResult(
        replacement: custom,
        snapshot: snapshot,
        displayRevision: _revision(
          mode,
          formal,
          null,
          customSnapshot.revision,
          config.temporaryOriginal,
        ),
        formal: formal,
        error: custom.error,
      );
    }

    // No formal result yet: keep the old user replacement visible while the
    // reader shows an "uncorrected" status. Requesting is the coordinator's
    // job; composition must stay read-only and fast.
    if (formal == null ||
        formal.canonicalVersion != snapshot.canonicalVersion ||
        formal.paragraphBoundaryFingerprint !=
            snapshot.paragraphBoundaryFingerprint) {
      final custom = await engine.transform(
        source: content,
        chapterTitle: chapterTitle,
        snapshot: customSnapshot,
      );
      return AiCompositionResult(
        replacement: custom,
        snapshot: snapshot,
        displayRevision: _revision(
          mode,
          null,
          null,
          customSnapshot.revision,
          config.temporaryOriginal,
        ),
        error: custom.error,
      );
    }

    final rawValidation = _validator.validateContent(
      jsonEncode({'edits': formal.edits.map((e) => e.toJson()).toList()}),
      snapshot,
    );
    if (!rawValidation.valid) {
      final custom = await engine.transform(
        source: content,
        chapterTitle: chapterTitle,
        snapshot: customSnapshot,
      );
      return AiCompositionResult(
        replacement: custom,
        snapshot: snapshot,
        displayRevision: _revision(
          mode,
          formal,
          null,
          customSnapshot.revision,
          config.temporaryOriginal,
        ),
        formal: formal,
        error: '正式校对结果未通过复核，已显示原文',
      );
    }

    final protections = await _feedback.activeProtections(
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
    );
    final kept = <AiRawEdit>[];
    final blockedEdits = <AiBlockedEdit>[];
    var skipped = 0;
    for (final raw in formal.edits) {
      final span = _spanFor(raw, rawValidation.spans);
      if (span == null) continue;
      final blockers = protections
          .where(
            (protection) =>
                protection.intersects(span.sourceStart, span.sourceEnd) &&
                !config.previews(span.sourceStart, span.sourceEnd),
          )
          .toList(growable: false);
      if (blockers.isNotEmpty) {
        skipped++;
        blockedEdits.add(
          AiBlockedEdit(
            span: span,
            protectionIds: blockers
                .map((protection) => protection.protectionId)
                .toList(growable: false),
            keepOriginal: blockers.any(
              (protection) => protection.isKeepOriginal,
            ),
          ),
        );
      } else {
        kept.add(raw);
      }
    }

    final approvedRaw = <AiRawEdit>[];
    final approvedKeys = <(int, int, String)>{};
    for (final protection in protections) {
      final approved = protection.approvedEdit;
      if (!protection.isKeepApproved || approved == null) continue;
      if (config.previews(protection.sourceStart, protection.sourceEnd)) {
        continue;
      }
      if (approved.original.isEmpty) continue;
      final start = approved.sourceStart;
      final end = approved.sourceEnd;
      if (start < 0 || end <= start || end > snapshot.requestText.length) {
        continue;
      }
      final paragraph = snapshot.paragraphIndexAt(start);
      if (paragraph == null ||
          paragraph != approved.paragraphIndex ||
          end > snapshot.paragraphEnd(paragraph)) {
        continue;
      }
      if (snapshot.requestText.substring(start, end) != approved.original) {
        continue;
      }
      final raw = AiRawEdit(
        original: approved.original,
        replacement: approved.replacement,
        category: approved.category ?? '认可改法',
        reason: approved.reason ?? '此前已认可的修改',
      );
      // An approved edit must not itself collide with a keep_original range.
      final blocked = protections.any(
        (other) =>
            other.isKeepOriginal &&
            other.intersects(start, end) &&
            !config.previews(start, end),
      );
      if (blocked) continue;
      approvedRaw.add(raw);
      approvedKeys.add((start, end, approved.replacement));
    }

    final combined = [...kept, ...approvedRaw];
    final validation = combined.isNotEmpty
        ? _validator.validateContent(
            jsonEncode({'edits': combined.map((e) => e.toJson()).toList()}),
            snapshot,
          )
        : AiValidationResult.success(edits: const [], spans: const []);
    if (!validation.valid) {
      final custom = await engine.transform(
        source: content,
        chapterTitle: chapterTitle,
        snapshot: customSnapshot,
      );
      return AiCompositionResult(
        replacement: custom,
        snapshot: snapshot,
        displayRevision: _revision(
          mode,
          formal,
          protections,
          customSnapshot.revision,
          config.temporaryOriginal,
        ),
        formal: formal,
        protections: protections,
        rawCount: formal.edits.length,
        skippedByProtection: skipped,
        error: '保护过滤后的编辑无法安全合成，已显示原文',
      );
    }

    final applied = AiApply.apply(
      snapshot: snapshot,
      source: content,
      spans: validation.spans,
      approvedKeys: approvedKeys,
    );
    final custom = await engine.transform(
      source: applied.content,
      chapterTitle: chapterTitle,
      snapshot: customSnapshot,
    );
    final displaySpans = _mapSpansToFinalDisplay(
      snapshot: snapshot,
      applied: applied,
      custom: custom,
    );
    final combinedMaps = <int, TextOffsetMap>{};
    final blockIndices = <int>{
      ...applied.paragraphMaps.keys,
      ...custom.paragraphMaps.keys,
    };
    for (final index in blockIndices) {
      final aiMap = applied.paragraphMaps[index];
      final customMap = custom.paragraphMaps[index];
      if (aiMap == null && customMap == null) continue;
      if (aiMap == null) {
        combinedMaps[index] = customMap!;
      } else if (customMap == null) {
        combinedMaps[index] = aiMap;
      } else {
        combinedMaps[index] = aiMap.followedBy(customMap);
      }
    }
    final replacement = TextReplacementResult(
      source: content,
      content: custom.content,
      snapshotRevision: customSnapshot.revision,
      paragraphMaps: Map.unmodifiable(combinedMaps),
      error: custom.error,
    );
    return AiCompositionResult(
      replacement: replacement,
      snapshot: snapshot,
      displayRevision: _revision(
        mode,
        formal,
        protections,
        customSnapshot.revision,
        config.temporaryOriginal,
      ),
      applied: applied,
      formal: formal,
      rawCount: formal.edits.length,
      skippedByProtection: skipped,
      approvedCount: approvedRaw.length,
      protections: protections,
      displaySpans: displaySpans,
      blockedEdits: List.unmodifiable(blockedEdits),
      error: custom.error,
    );
  }

  static List<AiEditSpan> _mapSpansToFinalDisplay({
    required AiChapterSnapshot snapshot,
    required AiApplyResult applied,
    required TextReplacementResult custom,
  }) {
    final result = <AiEditSpan>[];
    for (final span in applied.spans) {
      var deltaBefore = 0;
      for (var p = 0; p < span.paragraphIndex; p++) {
        final blockIndex = snapshot.paragraphBlockIndices[p];
        final map = custom.paragraphMaps[blockIndex];
        if (map != null) {
          deltaBefore += map.displayLength - map.sourceLength;
        }
      }
      final base =
          applied.paragraphDisplayStarts[span.paragraphIndex] + deltaBefore;
      final map = custom.paragraphMaps[span.blockIndex];
      final localStart =
          span.displayStart -
          applied.paragraphDisplayStarts[span.paragraphIndex];
      final localEnd =
          span.displayEnd - applied.paragraphDisplayStarts[span.paragraphIndex];
      final displayStart =
          base +
          (map?.toDisplay(localStart, bias: TextBoundaryBias.start) ??
              localStart);
      final displayEnd =
          base +
          (map?.toDisplay(localEnd, bias: TextBoundaryBias.end) ?? localEnd);
      result.add(
        span.copyWith(displayStart: displayStart, displayEnd: displayEnd),
      );
    }
    return List.unmodifiable(result);
  }

  AiCompositionResult unavailable({
    required ChapterContent content,
    required AiChapterSnapshot snapshot,
    required TextReplacementSnapshot customSnapshot,
    required AiCompositionConfig config,
    String? error,
  }) {
    return AiCompositionResult(
      replacement: TextReplacementResult(
        source: content,
        content: content,
        snapshotRevision: customSnapshot.revision,
      ),
      snapshot: snapshot,
      displayRevision: _revision(
        config.effectiveMode,
        null,
        null,
        customSnapshot.revision,
        config.temporaryOriginal,
      ),
      error: error,
    );
  }

  static AiEditSpan? _spanFor(AiRawEdit raw, List<AiEditSpan> spans) {
    for (final span in spans) {
      if (span.original == raw.original &&
          span.replacement == raw.replacement) {
        return span;
      }
    }
    return null;
  }

  static int _revision(
    AiDisplayMode mode,
    AiFormalCacheEntry? formal,
    List<AiFeedbackProtection>? protections,
    int customRevision,
    bool temporaryOriginal,
  ) {
    var protectionRevision = 0;
    if (protections != null) {
      for (final protection in protections) {
        protectionRevision =
            protectionRevision * 31 +
            protection.protectionId.hashCode +
            protection.updatedAt.millisecondsSinceEpoch;
      }
    }
    return Object.hash(
      mode,
      formal?.activeRunId,
      formal?.updatedAt.millisecondsSinceEpoch,
      protectionRevision,
      customRevision,
      temporaryOriginal,
    );
  }
}
