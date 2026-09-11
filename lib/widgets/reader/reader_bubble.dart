import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// Geometry of an in-text paragraph-comment bubble.
///
/// Note: these numbers and the ring shape are the official client's, decompiled
/// from `n02/e.java` and measured from its own drawable assets — see
/// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
@immutable
class ReaderBubbleMetrics {
  const ReaderBubbleMetrics({required this.textSize, required this.diameter});

  final double textSize;

  /// Outer diameter. The official bubble is a circle, so width and height are
  /// the same; the skin drawable is 26x24dp only because it leaves room for the
  /// label to be laid out wider than the ring.
  final double diameter;

  double get width => diameter;
  double get height => diameter;

  /// Border width. The official drawable's ring measures 4px at 3x.
  static const strokeWidth = 4 / 3;

  /// Horizontal gap between the paragraph's last glyph and the bubble. This is
  /// `ParaBubbleInlineConfig.margin`, whose default is 8dp.
  static const gap = 8.0;

  /// Picks the size class from the reader's effective font size, exactly as the
  /// official client does: <=19sp small, <=29sp normal, above that large.
  factory ReaderBubbleMetrics.forFontSize(double fontSize) => fontSize <= 19
      ? const ReaderBubbleMetrics(textSize: 8, diameter: 24)
      : fontSize <= 29
      ? const ReaderBubbleMetrics(textSize: 9, diameter: 26)
      : const ReaderBubbleMetrics(textSize: 10, diameter: 30);

  /// Three digits no longer fit, so the official client steps the label down one
  /// size for the larger classes. Small is already at the floor.
  ReaderBubbleMetrics forCount(int count) {
    if (count <= overflowThreshold) return this;
    return ReaderBubbleMetrics(
      textSize: textSize > 8 ? textSize - 1 : textSize,
      diameter: diameter,
    );
  }

  /// Counts above this are shown as `99+`.
  static const overflowThreshold = 99;
}

/// The count bubble drawn at the end of a paragraph that has paragraph
/// comments.
///
/// The official bubble is a **hollow ring** — its skin drawable is a black alpha
/// mask measuring 24dp across with a ~1.3dp stroke, tinted with the theme text
/// colour, and the paragraph's own text colour is used for the label inside. A
/// filled bubble would be a different control entirely.
///
/// The label is the count up to [ReaderBubbleMetrics.overflowThreshold] and
/// `99+` beyond it, which is what the official client renders while its
/// `para_bubble_inline_config_v645` switch is off (it is off by default; when
/// enabled the label becomes a compact `1.2万` form instead).
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

  String get label => count > ReaderBubbleMetrics.overflowThreshold
      ? '${ReaderBubbleMetrics.overflowThreshold}+'
      : '$count';

  @override
  Widget build(BuildContext context) {
    final size = metrics.forCount(count);
    final color = preset.mutedTextColor;
    final bubble = SizedBox.square(
      dimension: size.diameter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color,
            width: ReaderBubbleMetrics.strokeWidth,
          ),
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontSize: size.textSize,
              height: 1,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
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
