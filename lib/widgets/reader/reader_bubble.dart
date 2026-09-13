import 'package:flutter/material.dart';

import '../../models/chapter_ideas.dart';
import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// Geometry and artwork of an in-text paragraph-comment bubble.
///
/// The sizes, label rules and the assets themselves are the official client's.
/// The official view (`f45/f` + `g45/a`) picks the mask from the paragraph's
/// idea data — `userCount > 0` draws the checkmark bubble, an author comment
/// the pen-nib bubble, everything else the plain one — and sizes it from
/// `n02/e` by the effective font size. All masks are black + alpha skin
/// drawables (`drawable-xxhdpi`), tinted at draw time with the theme colour —
/// see .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
@immutable
class ReaderBubbleMetrics {
  const ReaderBubbleMetrics({
    required this.textSize,
    required this.width,
    required this.height,
    required this.asset,
  });

  final double textSize;

  /// Box the official client gives the bubble, in dp. For the checkmark and
  /// pen-nib masks it is wider than tall because the tail sits to the right of
  /// the body; the plain mask is square.
  final double width;
  final double height;

  /// Official skin mask (black + alpha), tinted with the theme colour on draw.
  final String asset;

  /// Horizontal gap between the paragraph's last glyph and the bubble. This is
  /// `ParaBubbleInlineConfig.margin`, whose default is 8dp.
  static const gap = 8.0;

  /// Picks the size class from the reader's effective font size, exactly as the
  /// official client does: <=19sp small, <=29sp normal, above that large. The
  /// box tracks the chosen mask's own dp size (3x pixels / 3): the plain mask
  /// is square, the tail-bearing masks add ~2dp of width.
  factory ReaderBubbleMetrics.forFontSize(
    double fontSize, {
    ParagraphBubbleVariant variant = ParagraphBubbleVariant.plain,
  }) {
    final sizeClass = fontSize <= 19
        ? 0
        : fontSize <= 29
        ? 1
        : 2;
    final (textSize, width, height) = switch (variant) {
      ParagraphBubbleVariant.plain => switch (sizeClass) {
        0 => (8.0, 24.0, 24.0),
        1 => (9.0, 26.0, 26.0),
        _ => (10.0, 30.0, 30.0),
      },
      ParagraphBubbleVariant.users => switch (sizeClass) {
        0 => (8.0, 26.0, 24.0),
        1 => (9.0, 28.0, 26.0),
        _ => (10.0, 97 / 3, 30.0),
      },
      ParagraphBubbleVariant.author => switch (sizeClass) {
        0 => (8.0, 26.0, 24.0),
        1 => (9.0, 28.0, 26.0),
        _ => (10.0, 32.0, 30.0),
      },
    };
    final group = switch (variant) {
      ParagraphBubbleVariant.plain => 'plain',
      ParagraphBubbleVariant.users => 'users',
      ParagraphBubbleVariant.author => 'author',
    };
    final suffix = switch (sizeClass) {
      0 => 'small',
      1 => 'normal',
      _ => 'large',
    };
    return ReaderBubbleMetrics(
      textSize: textSize,
      width: width,
      height: height,
      asset: 'assets/images/bubble/para_bubble_${group}_$suffix.webp',
    );
  }

  /// Three digits no longer fit, so the official client steps the label down one
  /// size for the larger classes. Small is already at the floor.
  ReaderBubbleMetrics forCount(int count) {
    if (count <= overflowThreshold) return this;
    if (textSize <= 8) return this;
    return ReaderBubbleMetrics(
      textSize: textSize - 1,
      width: width,
      height: height,
      asset: asset,
    );
  }

  /// Counts above this are shown as `99+`.
  static const overflowThreshold = 99;
}

/// The count bubble drawn at the end of a paragraph that has paragraph
/// comments.
///
/// The artwork is the official client's own skin asset: a black alpha mask of a
/// speech-bubble outline tinted at draw time with the theme text colour — the
/// same `p.o(drawable, colour)` the official view performs on its ImageView.
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
    final bubble = SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Image.asset(
            size.asset,
            width: size.width,
            height: size.height,
            fit: BoxFit.fill,
            color: color,
            colorBlendMode: BlendMode.srcIn,
            gaplessPlayback: true,
            semanticLabel: null,
          ),
          Text(
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
        ],
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
