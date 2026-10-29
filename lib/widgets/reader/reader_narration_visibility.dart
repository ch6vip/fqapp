import 'package:flutter/widgets.dart';

import 'reader_chapter_layout.dart';

/// Uses measured line bounds, not a paginated-page approximation when scrolling.
bool readerNarrationOnScreen({
  required ReaderChapterLayout? layout,
  required (int, int)? range,
  required bool paged,
  required int pageIndex,
  ScrollController? scrollController,
  double? scrollOffset,
  double? viewportHeight,
}) {
  if (layout == null || range == null || range.$2 <= range.$1) return false;
  if (paged) {
    if (pageIndex < 0 || pageIndex >= layout.pages.length) return false;
    final page = layout.pages[pageIndex];
    return range.$1 < page.end && range.$2 > page.start;
  }
  final viewport = scrollController?.positions.firstOrNull;
  scrollOffset ??= viewport?.pixels;
  viewportHeight ??= viewport?.viewportDimension;
  if (scrollOffset == null || viewportHeight == null || viewportHeight <= 0) {
    return false;
  }
  final top = scrollOffset - layout.spec.verticalPadding;
  final bottom = top + viewportHeight;
  for (final block in layout.blocks) {
    if (block.top >= bottom || block.start >= range.$2) break;
    if (block.isImage ||
        block.top + block.height <= top ||
        block.end <= range.$1) {
      continue;
    }
    for (final line in block.lines) {
      if (block.start + line.start < range.$2 &&
          block.start + line.end > range.$1 &&
          block.top + line.top < bottom &&
          block.top + line.bottom > top) {
        return true;
      }
    }
  }
  return false;
}
