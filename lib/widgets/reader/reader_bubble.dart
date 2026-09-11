import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// Geometry of an in-text paragraph-comment bubble.
///
/// Note: these numbers are the official client's, decompiled from
/// `n02/e.java` — see
/// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
@immutable
class ReaderBubbleMetrics {
  const ReaderBubbleMetrics({
    required this.textSize,
    required this.width,
    required this.height,
  });

  final double textSize;
  final double width;
  final double height;

  /// Horizontal gap between the paragraph's last glyph and the bubble.
  static const gap = 6.0;

  /// Picks the size class from the reader's effective font size, exactly as the
  /// official client does: <=19sp small, <=29sp normal, above that large.
  factory ReaderBubbleMetrics.forFontSize(double fontSize) => fontSize <= 19
      ? const ReaderBubbleMetrics(textSize: 8, width: 26, height: 24)
      : fontSize <= 29
      ? const ReaderBubbleMetrics(textSize: 9, width: 28, height: 26)
      : const ReaderBubbleMetrics(textSize: 10, width: 32, height: 30);

  /// A three-digit-plus count no longer fits the normal text size, so the
  /// official client steps the font down one and widens the box to the square
  /// size. Both changes are reproduced from the same source.
  ReaderBubbleMetrics forCount(int count) {
    if (count <= 999) return this;
    return ReaderBubbleMetrics(
      textSize: textSize > 8 ? textSize - 1 : textSize,
      width: height,
      height: height,
    );
  }
}

/// The count bubble drawn at the end of a paragraph that has paragraph
/// comments.
///
/// The official bubble contains only the number — no avatar and no comment
/// text — which is all the idea list can supply anyway (it returns counts and
/// comment ids, not bodies).
class ReaderParagraphBubble extends StatelessWidget {
  final int count;
  final ReaderBubbleMetrics metrics;
  final ReaderThemePreset preset;
  final VoidCallback? onTap;

  const ReaderParagraphBubble({
    super.key,
    required this.count,
    required this.metrics,
    required this.preset,
    this.onTap,
  });

  /// Counts at or above this become `999+`, as the official client does.
  static const overflowThreshold = 1000;

  String get label =>
      count >= overflowThreshold ? '${overflowThreshold - 1}+' : '$count';

  @override
  Widget build(BuildContext context) {
    final size = metrics.forCount(count);
    final bubble = Container(
      width: size.width,
      height: size.height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // Tinted from the reader theme so the bubble reads correctly on all four
        // backgrounds and in night mode; the official one is skinned the same
        // way rather than using a fixed colour.
        color: preset.mutedTextColor.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size.height / 2),
      ),
      child: Text(
        label,
        maxLines: 1,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: preset.mutedTextColor,
          fontSize: size.textSize,
          height: 1,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.only(left: ReaderBubbleMetrics.gap),
        child: bubble,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: ReaderBubbleMetrics.gap),
      child: GestureDetector(
        key: ValueKey('reader-para-bubble-$count'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: bubble,
      ),
    );
  }
}
