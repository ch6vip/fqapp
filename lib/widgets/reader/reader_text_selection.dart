import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, TextBox;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../services/reader_underline_store.dart';
import 'reader_chapter_layout.dart';

// Note: 选区模型、几何注册表与官方橙配色的来龙去脉 —
// 见 .agents/notes/implemented/feature/2026-09-19-reader-selection-model.md

/// A live text selection, in the chapter's display-text coordinate space —
/// the same offsets `ReaderContentBlock.start` uses. Created whole-paragraph
/// by a long press, then reshaped character-by-character by dragging a handle.
@immutable
class ReaderTextSelection {
  /// Inclusive first character offset.
  final int start;

  /// Exclusive end offset.
  final int end;

  /// True when the selection still covers exactly one paragraph — the state a
  /// long press creates. The action bar offers 从本段听 only here.
  final bool isWholeParagraph;

  const ReaderTextSelection({
    required this.start,
    required this.end,
    this.isWholeParagraph = false,
  });

  int get length => end - start;
  bool get isValid => end > start;

  ReaderTextSelection copyWith({int? start, int? end, bool? isWholeParagraph}) =>
      ReaderTextSelection(
        start: start ?? this.start,
        end: end ?? this.end,
        isWholeParagraph: isWholeParagraph ?? this.isWholeParagraph,
      );

  /// Moves one bound to [offset] within the chapter text of length
  /// [textLength], keeping the selection non-empty: a drag landing exactly on
  /// the opposite bound pins one character instead of collapsing, so the
  /// finger never loses the selection mid-gesture and can drag back out. A
  /// drag past the other bound swaps the range, like the official native
  /// update that always answers with a non-empty range.
  // Note: 拖动边界对齐官方（非空不变量、分隔符守卫）—
  // 见 .agents/notes/implemented/bug-fix/2026-09-19-selection-drag-boundary.md
  ReaderTextSelection withBound({
    required bool isStart,
    required int offset,
    required int textLength,
  }) {
    if (isStart) {
      if (offset < end) return copyWith(start: offset);
      final swapped = ReaderTextSelection(
        start: end,
        end: offset > end ? offset : end + 1,
      );
      return swapped.end <= textLength
          ? swapped
          : ReaderTextSelection(start: end - 1, end: end);
    }
    if (offset > start) return copyWith(end: offset);
    final swappedStart = offset < start ? offset : start - 1;
    if (swappedStart >= 0) {
      return ReaderTextSelection(start: swappedStart, end: start);
    }
    return ReaderTextSelection(
      start: start,
      end: math.min(start + 1, textLength),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderTextSelection &&
      other.start == start &&
      other.end == end &&
      other.isWholeParagraph == isWholeParagraph;

  @override
  int get hashCode => Object.hash(start, end, isWholeParagraph);
}

/// The part of the chapter-space range [start]..[end] that falls inside
/// [block], in block-text coordinates, or null when disjoint.
(int, int)? blockSelectionRange(ReaderContentBlock block, int start, int end) {
  final from = math.max(start, block.start) - block.start;
  final to = math.min(end, block.end) - block.start;
  if (to <= from) return null;
  return (from, to);
}

/// The block-text line holding [offset] (the last line when the offset sits
/// on the block's end boundary).
ReaderTextLine lineForOffset(ReaderContentBlock block, int offset) {
  ReaderTextLine? found;
  for (final line in block.lines) {
    if (line.start > offset) break;
    found = line;
    if (offset < line.end) break;
  }
  return found ?? block.lines.first;
}

/// Snaps a raw hit-test offset down to the nearest grapheme-cluster start, so
/// a handle never lands inside an emoji or surrogate pair.
int snapToCharacter(String text, int offset) {
  final target = offset.clamp(0, text.length);
  var consumed = 0;
  var boundary = 0;
  for (final char in text.characters) {
    if (consumed > target) break;
    boundary = consumed;
    consumed += char.length;
  }
  return consumed <= target ? text.length : boundary;
}

/// Where a handle attaches for the selection bound at block-text [offset]:
/// the glyph box's outer edge on that line, in the block's coordinate space.
Offset selectionAnchor({
  required ReaderContentBlock block,
  required TextPainter painter,
  required int textOffset,
  required bool isStart,
  required double columnWidth,
}) {
  final line = lineForOffset(block, textOffset);
  var x = isStart ? 0.0 : columnWidth;
  final leading = block.isTitle ? 0 : 1;
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: textOffset + leading, extentOffset: textOffset + leading + 1),
    boxHeightStyle: BoxHeightStyle.tight,
  );
  if (boxes.isNotEmpty) {
    x = isStart ? boxes.first.left : boxes.first.right;
  }
  return Offset(x, isStart ? line.top : line.bottom);
}

/// One mounted block's hit-test assets, registered by [ReaderBlockMarkLayer].
@immutable
class ReaderSelectionEntry {
  final int blockIndex;
  final ReaderContentBlock block;
  final RenderBox box;
  final TextPainter painter;

  /// The block-space y window this entry answers for: the whole block in
  /// scroll mode, the visible lines' span in paged mode — so a point between
  /// two fragments resolves to the page actually showing it.
  final double windowTop;
  final double windowBottom;

  const ReaderSelectionEntry({
    required this.blockIndex,
    required this.block,
    required this.box,
    required this.painter,
    required this.windowTop,
    required this.windowBottom,
  });

  double distanceTo(double y) {
    if (y < windowTop) return windowTop - y;
    if (y > windowBottom) return y - windowBottom;
    return 0;
  }
}

/// Per-mounted-block painters and boxes, so a handle drag can resolve the
/// chapter offset under the finger across paragraph (and page) boundaries —
/// the drag starts at one handle but must keep selecting into the next
/// paragraph. Entries come and go with the mark layers;
/// [chapterOffsetAt] picks the entry whose window holds the point.
class ReaderSelectionGeometry {
  final List<ReaderSelectionEntry> _entries = [];

  void register({required ReaderSelectionEntry entry}) {
    unregister(entry.blockIndex);
    _entries.add(entry);
  }

  void unregister(int blockIndex) =>
      _entries.removeWhere((entry) => entry.blockIndex == blockIndex);

  ReaderSelectionEntry? entryFor(int blockIndex) {
    for (final entry in _entries) {
      if (entry.blockIndex == blockIndex && entry.box.attached) return entry;
    }
    return null;
  }

  /// Nearest entry to [global], by block-space distance to the entry's
  /// window. Neighbor pages and off-screen list items are far away by
  /// construction, so the entry holding the finger wins outright.
  ReaderSelectionEntry? _entryAt(Offset global) {
    ReaderSelectionEntry? best;
    var bestDistance = double.infinity;
    for (final entry in _entries) {
      if (!entry.box.attached) continue;
      final local = entry.box.globalToLocal(global);
      final distance = entry.distanceTo(local.dy);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = entry;
      }
    }
    return best;
  }

  /// The chapter display-text offset under [global], or null when no block is
  /// mounted close enough to answer.
  int? chapterOffsetAt(Offset global) {
    final entry = _entryAt(global);
    if (entry == null) return null;
    final local = entry.box.globalToLocal(global);
    final y = local.dy.clamp(0.0, math.max(0.0, entry.block.height - .01)).toDouble();
    final position = entry.painter.getPositionForOffset(Offset(local.dx, y));
    final leading = entry.block.isTitle ? 0 : 1;
    final textOffset = (position.offset - leading).clamp(
      0,
      entry.block.text.length,
    );
    return entry.block.start + snapToCharacter(entry.block.text, textOffset);
  }
}

/// Palette plus the hit-test registry; one per chapter layout, shared by
/// every mark layer and by the handle overlay the reader page owns.
class ReaderSelectionScope {
  final ReaderSelectionGeometry geometry;
  final Color washColor;
  final Color handleColor;
  final Color underlineColor;

  ReaderSelectionScope({
    required this.geometry,
    required this.washColor,
    required this.handleColor,
    required this.underlineColor,
  });
}

/// Paints the selection wash and range underlines behind [child], in the
/// block's own coordinate space, and registers the block with the scope's
/// hit-test registry.
///
/// Scroll mode mounts one per paragraph; paged mode mounts one per fragment
/// with [windowTop]/[windowBottom] narrowed to the visible lines, so a block
/// split across pages marks (and hit-tests) only the part on screen. Handles
/// are deliberately NOT here: a handle reaching past the block bounds would
/// fall outside every ancestor's hit-test box, so the reader page floats them
/// in a page-level overlay instead.
class ReaderBlockMarkLayer extends StatefulWidget {
  final ReaderContentBlock block;
  final ReaderLayoutSpec spec;
  final ReaderSelectionScope scope;
  final ReaderTextSelection? selection;
  final List<ReaderRangeUnderline> rangeUnderlines;
  final Widget child;

  /// Block-space y window; defaults to the whole block.
  final double windowTop;
  final double windowBottom;

  const ReaderBlockMarkLayer({
    super.key,
    required this.block,
    required this.spec,
    required this.scope,
    required this.selection,
    required this.rangeUnderlines,
    required this.child,
    this.windowTop = 0,
    this.windowBottom = double.infinity,
  });

  @override
  State<ReaderBlockMarkLayer> createState() => _ReaderBlockMarkLayerState();
}

class _ReaderBlockMarkLayerState extends State<ReaderBlockMarkLayer> {
  TextPainter? _painter;

  @override
  void initState() {
    super.initState();
    _scheduleRegistration();
  }

  @override
  void didUpdateWidget(ReaderBlockMarkLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.block, widget.block) ||
        oldWidget.spec != widget.spec) {
      _painter?.dispose();
      _painter = null;
    }
    _scheduleRegistration();
  }

  @override
  void dispose() {
    widget.scope.geometry.unregister(widget.block.index);
    _painter?.dispose();
    super.dispose();
  }

  TextPainter get _lazyPainter =>
      _painter ??= ReaderChapterLayout.blockPainter(widget.block, widget.spec);

  void _scheduleRegistration() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached) return;
      widget.scope.geometry.register(
        entry: ReaderSelectionEntry(
          blockIndex: widget.block.index,
          block: widget.block,
          box: box,
          painter: _lazyPainter,
          windowTop: widget.windowTop,
          windowBottom: widget.windowBottom.isInfinite
              ? widget.block.height
              : widget.windowBottom,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    final range = selection == null || !selection.isValid
        ? null
        : blockSelectionRange(widget.block, selection.start, selection.end);
    return Stack(
      children: [
        // First child paints first: the marks sit behind the text.
        Positioned.fill(
          child: CustomPaint(
            painter: ReaderBlockMarkPainter(
              block: widget.block,
              painter: _lazyPainter,
              selectionRange: range,
              rangeUnderlines: widget.rangeUnderlines,
              washColor: widget.scope.washColor,
              underlineColor: widget.scope.underlineColor,
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// The official droplet: a 3dp-radius circle with a 1dp stem of roughly
/// 1.4em, hanging above (start) or below (end) the selected line. The stem
/// tip is the anchor; the touch target is far larger than the ink, with the
/// spare space on the far side of the anchor (`n.java` inflates to 24x16dp).
class ReaderSelectionHandle extends StatelessWidget {
  final bool isStart;
  final Color color;
  final double fontSize;
  final VoidCallback onDragStart;
  final void Function(Offset globalPosition) onDragUpdate;
  final void Function(Offset globalPosition) onDragEnd;

  const ReaderSelectionHandle({
    super.key,
    required this.isStart,
    required this.color,
    required this.fontSize,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  static const _circleRadius = 3.0;

  /// Horizontal touch/ink span; the overlay positions the widget by this.
  static const touchWidth = 24.0;
  static const _touchMargin = 16.0;

  double get stemLength => fontSize * 1.4 + 2;
  double get height => stemLength + _circleRadius * 2 + _touchMargin;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => onDragStart(),
    onPanUpdate: (details) => onDragUpdate(details.globalPosition),
    onPanEnd: (details) => onDragEnd(details.globalPosition),
    child: CustomPaint(
      size: Size(touchWidth, height),
      painter: _HandlePainter(
        isStart: isStart,
        color: color,
        stemLength: stemLength,
      ),
    ),
  );
}

class _HandlePainter extends CustomPainter {
  final bool isStart;
  final Color color;
  final double stemLength;

  static const _circleRadius = 3.0;

  const _HandlePainter({
    required this.isStart,
    required this.color,
    required this.stemLength,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    // Ink occupies the far side of the widget from the anchor: the start
    // handle hangs above its line top, the end one below its line bottom,
    // each with the touch margin clear of the glyphs. The stem tip (the
    // anchor edge) is what touches the text.
    final (Offset circleCenter, Offset stemTip) = isStart
        ? (
            Offset(size.width / 2, size.height - stemLength - _circleRadius),
            Offset(size.width / 2, size.height),
          )
        : (
            Offset(size.width / 2, stemLength + _circleRadius),
            Offset(size.width / 2, 0),
          );
    canvas.drawLine(circleCenter, stemTip, paint..strokeWidth = 1);
    canvas.drawCircle(circleCenter, _circleRadius, paint);
  }

  @override
  bool shouldRepaint(_HandlePainter old) => old.color != color;
}

/// Paints, behind the text: the selection wash (per-line rounded rects around
/// the selected glyphs) and straight range underlines. Line vertical extents
/// come from the measured [ReaderTextLine]s, horizontal extents from glyph
/// boxes of the shared hit-test painter — the same painter the drag uses, so
/// marks and hit-testing can never disagree about the geometry.
class ReaderBlockMarkPainter extends CustomPainter {
  final ReaderContentBlock block;
  final TextPainter painter;
  final (int, int)? selectionRange;
  final List<ReaderRangeUnderline> rangeUnderlines;
  final Color washColor;
  final Color underlineColor;

  const ReaderBlockMarkPainter({
    required this.block,
    required this.painter,
    required this.selectionRange,
    required this.rangeUnderlines,
    required this.washColor,
    required this.underlineColor,
  });

  /// Per-line glyph rects for a block-text range: the vertical span of the
  /// measured line, the horizontal span of the glyphs.
  List<Rect> _lineRects(int from, int to) {
    if (to <= from) return const [];
    final leading = block.isTitle ? 0 : 1;
    final rects = <Rect>[];
    for (final line in block.lines) {
      final lineStart = math.max(from, line.start);
      final lineEnd = math.min(to, line.end);
      if (lineEnd <= lineStart) continue;
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: lineStart + leading, extentOffset: lineEnd + leading),
        boxHeightStyle: BoxHeightStyle.tight,
      );
      for (final TextBox box in boxes) {
        if (box.right <= box.left) continue;
        rects.add(Rect.fromLTRB(box.left, line.top, box.right, line.bottom));
      }
    }
    return rects;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final wash = Paint()..color = washColor;
    final selection = selectionRange;
    if (selection != null) {
      for (final rect in _lineRects(selection.$1, selection.$2)) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(2)),
          wash,
        );
      }
    }
    final line = Paint()
      ..color = underlineColor
      ..strokeWidth = 1.6;
    for (final underline in rangeUnderlines) {
      final range = blockSelectionRange(block, underline.start, underline.end);
      if (range == null) continue;
      for (final rect in _lineRects(range.$1, range.$2)) {
        // Sit the stroke just under the glyphs, inside the line box.
        final y = rect.bottom - .5;
        canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), line);
      }
    }
  }

  @override
  bool shouldRepaint(ReaderBlockMarkPainter old) =>
      old.selectionRange != selectionRange ||
      !listEquals(old.rangeUnderlines, rangeUnderlines) ||
      old.washColor != washColor ||
      old.underlineColor != underlineColor;
}
