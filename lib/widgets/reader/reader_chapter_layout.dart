import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/chapter_text_formatter.dart';
import '../../services/reader_preferences.dart';
import 'reader_bubble.dart';
import 'reader_illustration.dart';
import 'reader_theme.dart';

/// Layout inputs exclude brightness and page mode, which do not change text.
@immutable
class ReaderLayoutSpec {
  final Size viewport;
  final TextScaler textScaler;
  final TextStyle bodyStyle;
  final TextStyle titleStyle;
  final TextAlign titleAlign;
  final double horizontalPadding;
  final double verticalPadding;
  final double paragraphSpacing;

  ReaderLayoutSpec({
    required this.viewport,
    required this.textScaler,
    required ReaderPreferences preferences,
    required String? fontFamily,
  }) : horizontalPadding = preferences.horizontalPadding,
       verticalPadding = preferences.verticalPadding,
       paragraphSpacing = preferences.paragraphSpacing,
       titleAlign = preferences.titleAlignment == ReaderTitleAlignment.center
           ? TextAlign.center
           : TextAlign.start,
       bodyStyle = TextStyle(
         inherit: false,
         color: preferences.themePreset.textColor,
         fontFamily: fontFamily,
         fontSize: preferences.fontSize,
         fontWeight: FontWeight.values[preferences.fontWeight ~/ 100 - 1],
         height: preferences.lineHeight,
         letterSpacing: preferences.letterSpacing,
         textBaseline: TextBaseline.alphabetic,
       ),
       titleStyle = TextStyle(
         inherit: false,
         color: preferences.themePreset.textColor,
         fontFamily: fontFamily,
         fontSize: preferences.titleSize,
         fontWeight: FontWeight.w600,
         height: 1.55,
         letterSpacing: 0,
         textBaseline: TextBaseline.alphabetic,
       );

  double get width => math.max(1, viewport.width - horizontalPadding * 2);
  double get pagePadding => math.min(verticalPadding, viewport.height / 4);
  double get pageHeight => math.max(1, viewport.height - pagePadding * 2);
  double get navigationHeight => math.max(48, textScaler.scale(14) * 1.4 + 24);
  double get footerHeight => navigationHeight + 12;

  @override
  bool operator ==(Object other) =>
      other is ReaderLayoutSpec &&
      viewport == other.viewport &&
      textScaler == other.textScaler &&
      bodyStyle == other.bodyStyle &&
      titleStyle == other.titleStyle &&
      titleAlign == other.titleAlign &&
      horizontalPadding == other.horizontalPadding &&
      verticalPadding == other.verticalPadding &&
      paragraphSpacing == other.paragraphSpacing;

  @override
  int get hashCode => Object.hash(
    viewport,
    textScaler,
    bodyStyle,
    titleStyle,
    titleAlign,
    horizontalPadding,
    verticalPadding,
    paragraphSpacing,
  );
}

@immutable
class ReaderTextLine {
  final int start;
  final int end;
  final double top;
  final double bottom;

  const ReaderTextLine(this.start, this.end, this.top, this.bottom);

  double get height => bottom - top;
}

@immutable
class ReaderContentBlock {
  final int index;
  final String text;
  final int start;
  final int legacyStart;
  final double top;
  final double height;
  final TextSpan span;
  final TextAlign align;
  final List<ReaderTextLine> lines;
  final ChapterImage? illustration;

  /// Upstream paragraph id, when the source carried one. Paragraph-comment
  /// bubbles are keyed by this, not by the block's ordinal position.
  final int? paraIndex;

  /// Paragraph-comment count rendered as a bubble at the end of the last line;
  /// null when the paragraph has none or the upstream gate did not pass.
  final int? bubbleCount;

  const ReaderContentBlock({
    required this.index,
    required this.text,
    required this.start,
    required this.legacyStart,
    required this.top,
    required this.height,
    required this.span,
    required this.align,
    required this.lines,
    this.illustration,
    this.paraIndex,
    this.bubbleCount,
  });

  int get end => start + text.length;
  bool get isTitle => index == 0;
  bool get isImage => illustration != null;
  bool get hasBubble => bubbleCount != null;
}

/// A slice retains its original paragraph layout, including justification.
/// Reflowing a substring here would change line breaks and repeat indentation.
@immutable
class ReaderPageFragment {
  final ReaderContentBlock block;
  final int firstLine;
  final int lastLine;
  final double top;

  const ReaderPageFragment({
    required this.block,
    required this.firstLine,
    required this.lastLine,
    required this.top,
  });

  double get sourceTop => block.lines[firstLine].top;
  double get height => block.lines[lastLine].bottom - sourceTop;
  int get start => block.start + block.lines[firstLine].start;
  int get end => block.start + block.lines[lastLine].end;
  String get text =>
      block.text.substring(start - block.start, end - block.start);
}

@immutable
class ReaderTextPage {
  final List<ReaderPageFragment> fragments;

  const ReaderTextPage(this.fragments);

  int get start => fragments.first.start;
  int get end => fragments.last.end;
  double get height => fragments.last.top + fragments.last.height;
}

// Note: 两种阅读方式共用行测量，进度保存规范化正文的文字偏移；见
// .agents/notes/implemented/feature/2026-09-10-reader-pagination.md
class ReaderChapterLayout {
  final ReaderLayoutSpec spec;
  final List<ReaderContentBlock> blocks;
  final List<ReaderTextPage> pages;
  final int textLength;
  final double contentHeight;
  final int legacyTextLength;

  ReaderChapterLayout._(
    this.spec,
    this.blocks,
    this.pages,
    this.textLength,
    this.contentHeight,
    this.legacyTextLength,
  );

  factory ReaderChapterLayout({
    required String title,
    required ChapterContent content,
    required ReaderLayoutSpec spec,
    Map<int, int> paragraphBubbles = const {},
    Widget Function(int paraIndex, int count)? bubbleBuilder,
  }) {
    final body = content.withoutLeadingTitle(title);
    final legacyText = [
      if (title.isNotEmpty) title,
      ...splitChapterParagraphs(body.legacyText),
    ].join('\n');
    final blocks = <ReaderContentBlock>[];
    var offset = 0;
    var legacyCursor = 0;
    var top = 0.0;
    for (final element in [ChapterParagraph(title), ...body.blocks]) {
      final text = element is ChapterParagraph ? element.text : '\uFFFC';
      var legacyStart = legacyCursor;
      if (element is ChapterParagraph) {
        final found = legacyText.indexOf(text, legacyCursor);
        if (found >= 0) legacyStart = found;
        legacyCursor = (legacyStart + text.length).clamp(0, legacyText.length);
      }
      final paraIndex = element is ChapterParagraph ? element.paraIndex : null;
      final bubbleCount = paraIndex == null
          ? null
          : paragraphBubbles[paraIndex];
      final bubble = bubbleCount == null || bubbleBuilder == null
          ? null
          : bubbleBuilder(paraIndex!, bubbleCount);
      final block = element is ChapterImage
          ? _measureImage(
              element,
              index: blocks.length,
              start: offset,
              legacyStart: legacyStart,
              top: top,
              spec: spec,
            )
          : _measureBlock(
              text,
              index: blocks.length,
              start: offset,
              legacyStart: legacyStart,
              top: top,
              spec: spec,
              paraIndex: paraIndex,
              bubbleCount: bubbleCount,
              bubble: bubble,
            );
      blocks.add(block);
      // An absent title contributes neither text nor a leading newline.
      offset += text.length + (block.isTitle && text.isEmpty ? 0 : 1);
      if (block.lines.isNotEmpty) {
        top += block.height + spec.paragraphSpacing;
      }
    }
    final pages = _paginate(blocks, spec);
    return ReaderChapterLayout._(
      spec,
      List.unmodifiable(blocks),
      List.unmodifiable(pages),
      math.max(0, offset - 1),
      top,
      legacyText.length,
    );
  }

  double get maxScroll => math.max(
    0,
    contentHeight +
        spec.verticalPadding * 2 +
        spec.footerHeight +
        32 -
        spec.viewport.height,
  );

  int pageForOffset(int offset) =>
      _floorIndex(pages.length, (index) => pages[index].start <= offset);

  int offsetFromLegacyText(int offset) {
    if (offset <= 0) return 0;
    final target = offset.clamp(0, legacyTextLength);
    var block = blocks.first;
    for (final candidate in blocks) {
      if (candidate.isImage || candidate.text.isEmpty) continue;
      if (candidate.legacyStart > target) break;
      block = candidate;
    }
    return block.start +
        (target - block.legacyStart).clamp(0, block.text.length);
  }

  int legacyOffsetForText(int offset) {
    if (offset <= 0) return 0;
    final block =
        blocks[_floorIndex(blocks.length, (i) => blocks[i].start <= offset)];
    return (block.legacyStart +
            (block.isImage
                ? 0
                : (offset - block.start).clamp(0, block.text.length)))
        .clamp(0, legacyTextLength);
  }

  /// The first visible line is the anchor, even when its top is partly clipped.
  int textOffsetAtScroll(double scroll) {
    final y = scroll - spec.verticalPadding;
    if (y <= 0) return 0;
    var index = _floorIndex(blocks.length, (index) => blocks[index].top <= y);
    var block = blocks[index];
    if (y >= block.top + block.height) {
      if (++index >= blocks.length) return textLength;
      block = blocks[index];
      return block.start;
    }
    final line = _floorIndex(
      block.lines.length,
      (index) => block.lines[index].top <= y - block.top,
    );
    return block.start + block.lines[line].start;
  }

  double scrollForTextOffset(int offset) {
    if (offset <= 0) return 0;
    if (offset >= textLength) return maxScroll;
    final block =
        blocks[_floorIndex(
          blocks.length,
          (index) => blocks[index].start <= offset,
        )];
    final line =
        block.lines[_floorIndex(
          block.lines.length,
          (index) => block.start + block.lines[index].start <= offset,
        )];
    return (spec.verticalPadding + block.top + line.top).clamp(0, maxScroll);
  }

  /// New positions are independent of font, page count and viewport size.
  /// Old records remain readable; pixel ratios are used only for migration.
  ({int textOffset, double scroll}) restore(
    Map<String, dynamic>? saved, {
    required String chapterId,
    required bool startAtEnd,
    required bool paged,
  }) {
    if (startAtEnd) {
      return (
        textOffset: paged ? pages.last.start : textOffsetAtScroll(maxScroll),
        scroll: maxScroll,
      );
    }
    if (saved?['chapterId']?.toString() != chapterId ||
        (saved?['kind'] != null && saved?['kind'] != 'book')) {
      return (textOffset: 0, scroll: 0);
    }
    final rawOffset = saved?['textOffset'];
    if ((saved?['positionVersion'] == 1 || saved?['positionVersion'] == 2) &&
        rawOffset is num &&
        rawOffset.isFinite &&
        rawOffset >= 0 &&
        rawOffset == rawOffset.truncateToDouble()) {
      final offset = saved?['positionVersion'] == 1
          ? offsetFromLegacyText(rawOffset.clamp(0, legacyTextLength).toInt())
          : rawOffset.clamp(0, textLength).toInt();
      return (textOffset: offset, scroll: scrollForTextOffset(offset));
    }
    final rawPosition = saved?['position'];
    final rawMax = saved?['maxScroll'];
    var scroll = 0.0;
    if (rawPosition is num && rawPosition.isFinite && rawPosition > 0) {
      scroll = rawMax is num && rawMax.isFinite && rawMax > 0
          ? maxScroll * (rawPosition / rawMax).clamp(0, 1)
          : rawPosition.toDouble().clamp(0, maxScroll);
    }
    return (textOffset: textOffsetAtScroll(scroll), scroll: scroll);
  }

  static ReaderContentBlock _measureBlock(
    String text, {
    required int index,
    required int start,
    required int legacyStart,
    required double top,
    required ReaderLayoutSpec spec,
    int? paraIndex,
    int? bubbleCount,
    Widget? bubble,
  }) {
    final title = index == 0;
    final style = title ? spec.titleStyle : spec.bodyStyle;
    final align = title ? spec.titleAlign : TextAlign.justify;
    final scale = spec.textScaler.scale(style.fontSize!) / style.fontSize!;
    final indent = math.min(
      (style.fontSize! + (style.letterSpacing ?? 0)) * 2,
      math.max(0.0, spec.width / scale - style.fontSize!),
    );
    // The bubble rides at the very end of the paragraph's text, so it follows
    // the last line and wraps only when that line has no room left. Measuring it
    // as a placeholder keeps paint and measurement in agreement.
    final metrics = bubble == null
        ? null
        : ReaderBubbleMetrics.forFontSize(
            spec.textScaler.scale(style.fontSize!),
          ).forCount(bubbleCount!);
    final bubbleSpan = bubble == null || metrics == null
        ? null
        : WidgetSpan(alignment: PlaceholderAlignment.middle, child: bubble);
    final span = TextSpan(
      style: style,
      children: [
        if (!title) WidgetSpan(child: SizedBox(width: indent, height: 0)),
        TextSpan(text: text),
        ?bubbleSpan,
      ],
    );
    if (title && text.isEmpty) {
      return ReaderContentBlock(
        index: index,
        text: text,
        start: start,
        legacyStart: legacyStart,
        top: top,
        height: 0,
        span: span,
        align: align,
        lines: const [],
        paraIndex: paraIndex,
        bubbleCount: bubbleCount,
      );
    }
    final painter = TextPainter(
      text: span,
      textAlign: align,
      textDirection: TextDirection.ltr,
      textScaler: spec.textScaler,
      locale: const Locale('zh', 'CN'),
    );
    try {
      if (!title) {
        painter.setPlaceholderDimensions([
          PlaceholderDimensions(
            size: Size(indent * scale, 0),
            alignment: PlaceholderAlignment.bottom,
          ),
          // The bubble's own left gap is inside the widget, so its placeholder
          // width has to include it or the trailing glyph and the bubble would
          // overlap.
          if (metrics != null)
            PlaceholderDimensions(
              size: Size(
                metrics.width + ReaderBubbleMetrics.gap,
                metrics.height,
              ),
              alignment: PlaceholderAlignment.middle,
            ),
        ]);
      }
      painter.layout(minWidth: spec.width, maxWidth: spec.width);
      final metricsList = painter.computeLineMetrics();
      final starts = <int>[];
      final tops = <double>[];
      // One placeholder per `\uFFFC`: the paragraph indent, then the bubble.
      final leading = title ? 0 : 1;
      final plainText =
          '${title ? '' : '\uFFFC'}$text${metrics == null ? '' : '\uFFFC'}';
      var cursor = 0;
      for (final line in metricsList) {
        // Hit-testing by y can jump into another line's emoji/RTL glyph box.
        // Walking logical line boundaries keeps offsets ordered in all fonts.
        var range = painter.getLineBoundary(TextPosition(offset: cursor));
        if (range.end <= cursor && cursor < plainText.length) {
          range = painter.getLineBoundary(TextPosition(offset: ++cursor));
        }
        starts.add((range.start - leading).clamp(0, text.length));
        tops.add(tops.isEmpty ? 0 : line.baseline - line.ascent);
        cursor = range.end;
        if (cursor < plainText.length && plainText.codeUnitAt(cursor) == 10) {
          cursor++;
        }
      }
      // Even an empty title has one measurable line in Flutter.
      if (starts.isEmpty) {
        starts.add(0);
        tops.add(0);
      }
      final boundaries = <int>{0};
      var characterOffset = 0;
      for (final character in text.characters) {
        boundaries.add(characterOffset += character.length);
      }
      // Some fallback fonts wrap a multi-codepoint emoji onto several lines.
      // Such a cluster, and any indent-only line, must stay on the same page.
      // A line holding only the bubble also has no cut of its own: it keeps
      // riding with the previous line so the bubble never lands alone.
      final cuts = <int>[0];
      for (var i = 1; i < starts.length; i++) {
        if (starts[i] > starts[cuts.last] &&
            starts[i] < text.length &&
            boundaries.contains(starts[i])) {
          cuts.add(i);
        }
      }
      return ReaderContentBlock(
        index: index,
        text: text,
        start: start,
        legacyStart: legacyStart,
        top: top,
        height: painter.height,
        span: span,
        align: align,
        lines: List.unmodifiable([
          for (var i = 0; i < cuts.length; i++)
            ReaderTextLine(
              starts[cuts[i]],
              i + 1 < cuts.length ? starts[cuts[i + 1]] : text.length,
              tops[cuts[i]],
              i + 1 < cuts.length ? tops[cuts[i + 1]] : painter.height,
            ),
        ]),
        paraIndex: paraIndex,
        bubbleCount: bubbleCount,
      );
    } finally {
      painter.dispose();
    }
  }

  static ReaderContentBlock _measureImage(
    ChapterImage image, {
    required int index,
    required int start,
    required int legacyStart,
    required double top,
    required ReaderLayoutSpec spec,
  }) {
    final ratio = image.aspectRatio;
    final usableRatio = ratio != null && ratio.isFinite && ratio > 0
        ? ratio
        : 3 / 4;
    // Reserve the full slot before loading. A decoded image never repaginates
    // the chapter or shifts saved text, and a tall image stays on one page.
    final height = math.min(spec.pageHeight, spec.width / usableRatio);
    return ReaderContentBlock(
      index: index,
      text: '\uFFFC',
      start: start,
      legacyStart: legacyStart,
      top: top,
      height: height,
      span: const TextSpan(),
      align: TextAlign.center,
      lines: [ReaderTextLine(0, 1, 0, height)],
      illustration: image,
    );
  }

  static List<ReaderTextPage> _paginate(
    List<ReaderContentBlock> blocks,
    ReaderLayoutSpec spec,
  ) {
    final pages = <ReaderTextPage>[];
    var fragments = <ReaderPageFragment>[];
    var used = 0.0;
    void finishPage() {
      if (fragments.isEmpty) return;
      pages.add(ReaderTextPage(List.unmodifiable(fragments)));
      fragments = [];
      used = 0;
    }

    for (final block in blocks) {
      if (block.lines.isEmpty) continue;
      for (var i = 0; i < block.lines.length; i++) {
        final line = block.lines[i];
        if (fragments.isNotEmpty &&
            used + line.height > spec.pageHeight + .001) {
          finishPage();
        }
        if (fragments.isNotEmpty && identical(fragments.last.block, block)) {
          final previous = fragments.removeLast();
          fragments.add(
            ReaderPageFragment(
              block: block,
              firstLine: previous.firstLine,
              lastLine: i,
              top: previous.top,
            ),
          );
        } else {
          fragments.add(
            ReaderPageFragment(
              block: block,
              firstLine: i,
              lastLine: i,
              top: used,
            ),
          );
        }
        used += line.height;
      }
      used += spec.paragraphSpacing;
    }
    finishPage();
    return pages;
  }
}

int _floorIndex(int length, bool Function(int) atOrBefore) {
  var low = 0;
  var high = length - 1;
  while (low < high) {
    final middle = (low + high + 1) ~/ 2;
    if (atOrBefore(middle)) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return low;
}

/// Shared by the scroll list and clipped page fragments.
class ReaderBlockContent extends StatelessWidget {
  final ReaderContentBlock block;
  final ReaderLayoutSpec spec;
  final ReaderImageProviderFactory? imageProviderFactory;

  const ReaderBlockContent({
    super.key,
    required this.block,
    required this.spec,
    this.imageProviderFactory,
  });

  @override
  Widget build(BuildContext context) {
    final image = block.illustration;
    return image != null
        ? ReaderIllustration(
            key: ValueKey('reader-illustration-${block.index}'),
            image: image,
            providerFactory: imageProviderFactory,
          )
        : ReaderBlockText(block: block, spec: spec);
  }
}

class ReaderBlockText extends StatelessWidget {
  final ReaderContentBlock block;
  final ReaderLayoutSpec spec;

  const ReaderBlockText({super.key, required this.block, required this.spec});

  @override
  Widget build(BuildContext context) {
    final key = block.isTitle
        ? const ValueKey('reader-chapter-title')
        : ValueKey('reader-paragraph-${block.index - 1}');
    return block.isTitle
        ? Text(
            block.text,
            key: key,
            style: block.span.style,
            textAlign: block.align,
            textScaler: spec.textScaler,
            textDirection: TextDirection.ltr,
            locale: const Locale('zh', 'CN'),
          )
        : Text.rich(
            block.span,
            key: key,
            style: block.span.style,
            textAlign: block.align,
            textScaler: spec.textScaler,
            textDirection: TextDirection.ltr,
            locale: const Locale('zh', 'CN'),
            semanticsLabel: block.text,
          );
  }
}
