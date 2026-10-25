/// Chapter content data shapes: blocks, paragraphs, inline elements, images.
///
/// Kept apart from the parser so the markup pipeline reads as one concern.
library;

import 'package:flutter/foundation.dart' show immutable;

sealed class ChapterBlock {
  const ChapterBlock();
}

class ChapterParagraph extends ChapterBlock {
  final String text;

  /// Upstream paragraph id from the `<p idx="N">` attribute.
  ///
  /// Chapter ideas (段评) are keyed by this id, so it is the only way to line a
  /// paragraph up with its comment count. Null for plain-text sources and for
  /// markup that carries no attribute.
  final int? paraIndex;

  /// Start of this paragraph's audio, in milliseconds from the beginning of the
  /// chapter, taken from the first `<span start_time="N">` inside it.
  ///
  /// Audio chapters ship the spoken timeline inline in the same markup that
  /// carries the text, so 从本段听 needs no extra request. Null for the many
  /// books without audio.
  ///
  /// Note: 段落时间轴就在正文标记里，官方与本地核心都没有独立接口 — 见
  /// .agents/notes/implemented/feature/2026-09-19-listen-from-paragraph.md
  final int? startMs;

  /// True for the `<img alt="...">` caption emitted when an image URL is
  /// unusable. It is real rendered text, but it must never be mistaken for the
  /// leading chapter title when the title is stripped.
  final bool isImageCaption;

  /// Spans of this paragraph's inline `<blk>` elements, in the order the parser
  /// met them.
  ///
  /// The audio timeline's `positionV2` addresses text as
  /// `(element index, offset inside it)` — the index of the `<blk>` and the
  /// character offset inside that element — so turning that into a paragraph
  /// offset needs these boundaries. Empty for markup without `<blk>`.
  final List<ChapterBlkSpan> blkSpans;

  const ChapterParagraph(
    this.text, {
    this.paraIndex,
    this.startMs,
    this.isImageCaption = false,
    this.blkSpans = const [],
  });
}

/// One inline `<blk>` element inside a paragraph.
///
/// `elementIndex` is the `e_idx` the timeline's `positionV2` refers to;
/// `start`/`length` locate the element inside the paragraph's rendered text.
@immutable
class ChapterBlkSpan {
  const ChapterBlkSpan({
    required this.elementIndex,
    required this.start,
    required this.length,
    this.startOffsetInPara,
  });

  final int elementIndex;
  final int start;
  final int length;
  final int? startOffsetInPara;

  int get end => start + length;
}

class ChapterImage extends ChapterBlock {
  final String url;
  final String alt;
  final double? width;
  final double? height;

  const ChapterImage({
    required this.url,
    this.alt = '',
    this.width,
    this.height,
  });

  double? get aspectRatio =>
      width != null && height != null ? width! / height! : null;
}

