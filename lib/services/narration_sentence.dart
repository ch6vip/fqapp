/// Sentence-level 句高亮 ranges for the system TTS reader wash.
///
/// The reader used to paint a whole utterance piece (up to 300 characters, so
/// three to six paragraphs) because that was the only range the player could
/// report. Engines that implement `onRangeStart` advance the offset word by
/// word, so the wash can follow the single sentence under the voice instead —
/// these helpers find that sentence and stay inside the piece.
// Note: .agents/notes/implemented/feature/2026-10-15-system-tts.md
library;

/// Characters that end a Chinese sentence. Deliberately the same set the
/// player uses when it backs a piece off to a sentence boundary, so a
/// sentence-level highlight can never straddle two pieces.
const String _sentenceEnders = '。！？!?；;\n';

/// Closing marks that belong to the sentence they follow (`。」`、`！”`).
const String _sentenceTrailers = '」』”’"\'）)》〉】';

/// The range the reader paints for the 句高亮.
///
/// [precise] says the engine reports word-level ranges, which is what lets the
/// wash follow the voice. Silent engines keep the whole piece: a frozen offset
/// would pin the highlight to the piece's first sentence until it ended.
///
/// Returns null before the first piece, when there is nothing to paint.
({int start, int end})? sentenceHighlightRange(
  String text, {
  required int offset,
  required int pieceStart,
  required int pieceEnd,
  required bool precise,
}) {
  if (pieceEnd <= pieceStart) return null;
  final piece = (start: pieceStart, end: pieceEnd);
  if (!precise) return piece;
  return sentenceRangeAt(
        text,
        offset,
        lower: pieceStart,
        upper: pieceEnd,
      ) ??
      piece;
}

/// The next utterance to hand the engine, starting at [cursor].
///
/// One sentence per utterance, because a longer slice is exactly what made the
/// 句高亮 paint whole paragraphs: an engine that never calls `onRangeStart` can
/// only report the slice it was given, so the slice has to be the sentence.
///
/// [maxLength] is the engine's input limit; an unusually long sentence is cut
/// there and continues as the following slice. The cut never lands inside a
/// surrogate pair. Returns null when only whitespace is left, which callers
/// read as "this chapter is done".
({int start, int end})? nextSentenceRange(
  String text,
  int cursor, {
  required int maxLength,
}) {
  var start = cursor.clamp(0, text.length).toInt();
  // The previous slice already spoke its trailing break; a lone '\n' would
  // otherwise become an utterance of its own.
  while (start < text.length && text[start].trim().isEmpty) {
    start++;
  }
  if (start >= text.length) return null;
  final limit = start + maxLength;
  var end = start;
  while (end < text.length &&
      end < limit &&
      !_sentenceEnders.contains(text[end])) {
    end++;
  }
  if (end < text.length && _sentenceEnders.contains(text[end])) {
    end++;
    // Closing marks belong to the sentence they end, so `」` is never the first
    // character of the next utterance.
    while (end < text.length && _sentenceTrailers.contains(text[end])) {
      end++;
    }
  }
  if (end > start && end < text.length) {
    final unit = text.codeUnitAt(end);
    if (unit >= 0xdc00 && unit <= 0xdfff) end--;
  }
  if (end <= start) return null;
  return (start: start, end: end);
}

/// The sentence around [offset], clamped to `[lower, upper)`.
///
/// [offset] is a character index into the piece being spoken. Returns null
/// when `[lower, upper)` holds no text.
({int start, int end})? sentenceRangeAt(
  String text,
  int offset, {
  required int lower,
  required int upper,
}) {
  final from = lower.clamp(0, text.length).toInt();
  final to = upper.clamp(from, text.length).toInt();
  if (to <= from) return null;
  final at = offset.clamp(from, to - 1).toInt();
  // Walk back to the previous sentence end; then step over the closing marks
  // and whitespace that end it, so `。」` does not start the next sentence.
  var start = at;
  while (start > from && !_sentenceEnders.contains(text[start - 1])) {
    start--;
  }
  while (start < at &&
      !_sentenceEnders.contains(text[start]) &&
      (_sentenceTrailers.contains(text[start]) || text[start].trim().isEmpty)) {
    start++;
  }
  var end = start;
  while (end < to && !_sentenceEnders.contains(text[end])) {
    end++;
  }
  if (end < to) {
    end++;
    while (end < to && _sentenceTrailers.contains(text[end])) {
      end++;
    }
  }
  if (end <= start) return null;
  return (start: start, end: end);
}
