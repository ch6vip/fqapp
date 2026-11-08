import '../chapter_text_formatter.dart';
import '../text_replacement_engine.dart';
import 'ai_models.dart';

/// One safe, display-only application of validated edits. The original
/// [ChapterContent] is never mutated; block count and block identity stay the
/// same, and every changed paragraph keeps its `paraIndex`/`startMs`/caption
/// flag. Inline audio spans are cleared because their offsets no longer match
/// the edited text.
class AiApplyResult {
  const AiApplyResult({
    required this.content,
    required this.spans,
    required this.paragraphMaps,
    required this.finalText,
    required this.paragraphDisplayStarts,
  });

  final ChapterContent content;
  final List<AiEditSpan> spans;

  /// Original block index -> source-to-display UTF-16 map for the edited
  /// paragraph. Unchanged paragraphs intentionally have no entry.
  final Map<int, TextOffsetMap> paragraphMaps;
  final String finalText;

  /// AI display start of every body paragraph, in the applied content.
  final List<int> paragraphDisplayStarts;
}

class AiApply {
  const AiApply._();

  static AiApplyResult apply({
    required AiChapterSnapshot snapshot,
    required ChapterContent source,
    required List<AiEditSpan> spans,
    Set<(int, int, String)> approvedKeys = const {},
  }) {
    final byParagraph = <int, List<AiEditSpan>>{};
    for (final span in spans) {
      byParagraph.putIfAbsent(span.paragraphIndex, () => []).add(span);
    }
    final finalParagraphs = <String>[];
    final paragraphDisplayStarts = <int>[];
    final maps = <int, TextOffsetMap>{};
    final updatedBlocks = [...source.blocks];
    var displayOffset = 0;

    for (
      var paragraph = 0;
      paragraph < snapshot.paragraphs.length;
      paragraph++
    ) {
      final original = snapshot.paragraphs[paragraph];
      final edits = byParagraph[paragraph];
      final blockIndex = snapshot.paragraphBlockIndices[paragraph];
      paragraphDisplayStarts.add(displayOffset);
      if (edits == null || edits.isEmpty) {
        finalParagraphs.add(original);
        displayOffset += original.length + 1;
        continue;
      }
      edits.sort((a, b) => a.sourceStart.compareTo(b.sourceStart));
      final buffer = StringBuffer();
      final segments =
          <({int start, int end, int outputStart, int outputEnd})>[];
      var sourceCursor = 0;
      var outputCursor = 0;
      for (final edit in edits) {
        final localStart =
            edit.sourceStart - snapshot.paragraphStart(paragraph);
        final localEnd = edit.sourceEnd - snapshot.paragraphStart(paragraph);
        if (localStart < sourceCursor || localEnd > original.length) {
          throw StateError('AI 编辑区间在合成时越界');
        }
        buffer.write(original.substring(sourceCursor, localStart));
        outputCursor += localStart - sourceCursor;
        final outputStart = outputCursor;
        buffer.write(edit.replacement);
        outputCursor += edit.replacement.length;
        segments.add((
          start: localStart,
          end: localEnd,
          outputStart: outputStart,
          outputEnd: outputCursor,
        ));
        sourceCursor = localEnd;
      }
      buffer.write(original.substring(sourceCursor));
      final displayText = buffer.toString();
      finalParagraphs.add(displayText);
      maps[blockIndex] = TextOffsetMap.fromSegments(
        original.length,
        displayText.length,
        segments,
      );
      final current = source.blocks[blockIndex];
      if (current is ChapterParagraph) {
        updatedBlocks[blockIndex] = ChapterParagraph(
          displayText,
          paraIndex: current.paraIndex,
          startMs: current.startMs,
          isImageCaption: current.isImageCaption,
          blkSpans: const [],
        );
      }
      displayOffset += displayText.length + 1;
    }

    // Recompute each span's display interval in the final body text. The
    // validator's provisional offsets are only used internally.
    final finalSpans = <AiEditSpan>[];
    for (final span in spans) {
      final paragraphStart = paragraphDisplayStarts[span.paragraphIndex];
      final map = maps[span.blockIndex];
      final localStart =
          span.sourceStart - snapshot.paragraphStart(span.paragraphIndex);
      final localEnd =
          span.sourceEnd - snapshot.paragraphStart(span.paragraphIndex);
      final displayStart =
          paragraphStart +
          (map?.toDisplay(localStart, bias: TextBoundaryBias.start) ??
              localStart);
      final displayEnd =
          paragraphStart +
          (map?.toDisplay(localEnd, bias: TextBoundaryBias.end) ?? localEnd);
      final approved = approvedKeys.contains((
        span.sourceStart,
        span.sourceEnd,
        span.replacement,
      ));
      finalSpans.add(
        span.copyWith(
          displayStart: displayStart,
          displayEnd: displayEnd,
          approved: approved,
        ),
      );
    }
    finalSpans.sort((a, b) => a.sourceStart.compareTo(b.sourceStart));

    return AiApplyResult(
      content: ChapterContent(
        blocks: updatedBlocks,
        legacyText: source.legacyText,
        illustrationsChecked: source.illustrationsChecked,
        paragraphIdsChecked: source.paragraphIdsChecked,
        timelineChecked: source.timelineChecked,
      ),
      spans: finalSpans,
      paragraphMaps: Map.unmodifiable(maps),
      finalText: finalParagraphs.join('\n'),
      paragraphDisplayStarts: List.unmodifiable(paragraphDisplayStarts),
    );
  }
}
