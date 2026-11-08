import 'package:flutter/material.dart';

/// A content anchor for the cached-media lists.
///
/// The classic and archive presentations of one cache use different row
/// heights and list preambles, so keeping only [ScrollController.offset]
/// across a style switch shows a different record at the same pixel offset.
/// This remembers the first visible record's stable id and how far its title
/// sits above the visible viewport, then re-scrolls to that record once the new
/// layout has completed.
///
/// Row widgets must be wrapped in [itemKey] so the anchor can find the same
/// record in both layouts. The owning page keeps this object (and its
/// [scroll] controller) above the shell branch, next to its existing content
/// key, so switching the theme never creates a second list owner or reloads
/// the store.
class CacheListAnchor {
  CacheListAnchor({required this.debugLabel});

  final String debugLabel;
  final ScrollController scroll = ScrollController();
  final Map<String, GlobalKey> _keys = {};
  final Map<String, String> _titles = {};
  _AnchorPoint? _pending;

  static const _maxApproximatePasses = 2;
  static const _maxRestorePasses = 8;

  /// Stable identity for one list row, shared by classic and archive.
  GlobalKey itemKey(String id, {String? title}) {
    if (title != null) _titles[id] = title;
    return _keys.putIfAbsent(
      id,
      () => GlobalKey(debugLabel: '$debugLabel/$id'),
    );
  }

  /// The list viewport runs behind the opaque AppBar/header, so the first
  /// usable row starts below that header. Both cache shells use the standard
  /// toolbar height; measuring from the raw viewport top would restore a row
  /// hidden under the AppBar.
  double _visibleTop(BuildContext context) {
    // Classic uses a real AppBar (Scaffold knows its status+toolbar height);
    // archive draws the floating header inside the body, so its height is the
    // status padding plus the standard toolbar.
    final appBarHeight = Scaffold.maybeOf(context)?.appBarMaxHeight;
    if (appBarHeight != null) return appBarHeight;
    return MediaQuery.paddingOf(context).top + kToolbarHeight;
  }

  /// Captures the old layout before it is replaced.
  ///
  /// [contentContext] is the context of the list shell (the page's existing
  /// content [GlobalKey]); [ids] is the row order currently rendered.
  void capture(BuildContext contentContext, Iterable<String> ids) {
    _pending = null;
    if (!scroll.hasClients) return;
    final viewport = contentContext.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached) return;
    final viewportTop =
        viewport.localToGlobal(Offset.zero).dy + _visibleTop(contentContext);
    final viewportBottom =
        viewport.localToGlobal(Offset.zero).dy + viewport.size.height;
    final order = ids.toList(growable: false);
    _AnchorPoint? fallback;
    for (var index = 0; index < order.length; index++) {
      // Anchor on the row title rather than the card top: classic and
      // archive use different internal padding, so preserving only the card
      // top would still move the visible title by that padding difference.
      final box = _titleBox(order[index]) ?? _rowBox(order[index]);
      if (box == null) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom <= viewportTop + 0.5) continue;
      final candidate = _AnchorPoint(
        id: order[index],
        index: index,
        order: order,
        intraOffset: viewportTop - top,
      );
      // Prefer the first fully visible row. A row whose top is just above the
      // viewport can fall out completely when the new style uses shorter rows,
      // which would leave a neighbouring record at the top instead.
      if (top >= viewportTop - 0.5 && bottom <= viewportBottom + 0.5) {
        _pending = candidate;
        return;
      }
      fallback ??= candidate;
    }
    _pending = fallback;
  }

  /// Restores the captured row after the new layout has been laid out.
  ///
  /// A shell switch can rebuild the page before its new ScrollPosition
  /// replaces the old one, and rows can be outside the new list's mounted
  /// range. The anchor therefore stays pending for a few frames: it
  /// re-measures after each layout, estimates the row position when it is not
  /// mounted, and only clears once the row has been stable for two frames.
  void restore(BuildContext contentContext) {
    final anchor = _pending;
    if (anchor == null) return;
    if (!contentContext.mounted || !scroll.hasClients) {
      _pending = null;
      return;
    }
    if (_rowMatchesAnchor(anchor, contentContext)) {
      if (++anchor.matchedFrames >= 2) {
        _pending = null;
        return;
      }
    } else {
      anchor.matchedFrames = 0;
      if (anchor.approximatePasses < _maxApproximatePasses &&
          _rowBox(anchor.id) == null) {
        final target = _approximateTarget(anchor, contentContext);
        if (target != null) {
          anchor.approximatePasses++;
          final position = scroll.position;
          scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent));
        }
      }
    }
    if (++anchor.restorePasses > _maxRestorePasses) {
      _pending = null;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pending == anchor) restore(contentContext);
    });
  }

  /// Returns true when the row is already at the captured viewport offset.
  /// Otherwise re-scrolls by the measured delta and returns false.
  bool _rowMatchesAnchor(_AnchorPoint anchor, BuildContext contentContext) {
    final viewport = contentContext.findRenderObject();
    final row = _titleBox(anchor.id) ?? _rowBox(anchor.id);
    if (viewport is! RenderBox || !viewport.attached || row == null) {
      return false;
    }
    final viewportTop =
        viewport.localToGlobal(Offset.zero).dy + _visibleTop(contentContext);
    final relative = row.localToGlobal(Offset.zero).dy - viewportTop;
    var delta = relative + anchor.intraOffset;
    // When row heights shrink, the row just above the anchor can become fully
    // visible and steal the "first visible" slot even though the anchor's own
    // offset was restored. Keep that previous row one pixel clipped.
    if (anchor.index > 0 && delta.abs() <= 8) {
      final previous =
          _titleBox(anchor.order[anchor.index - 1]) ??
          _rowBox(anchor.order[anchor.index - 1]);
      if (previous != null) {
        final previousTop =
            previous.localToGlobal(Offset.zero).dy - viewportTop;
        if (previousTop >= -0.5) delta += previousTop + 1.0;
      }
    }
    if (delta.abs() <= 0.5) return true;
    final position = scroll.position;
    scroll.jumpTo(
      (position.pixels + delta).clamp(0.0, position.maxScrollExtent),
    );
    return false;
  }

  void dispose() => scroll.dispose();

  /// Estimates where [anchor] would be from a row that is currently mounted.
  /// Only used to bring the exact row back into the keep-alive range.
  double? _approximateTarget(_AnchorPoint anchor, BuildContext contentContext) {
    final viewport = contentContext.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached) return null;
    final viewportTop =
        viewport.localToGlobal(Offset.zero).dy + _visibleTop(contentContext);
    for (var index = 0; index < anchor.order.length; index++) {
      if (index == anchor.index) continue;
      final sample = _rowBox(anchor.order[index]);
      if (sample == null) continue;
      final sampleTop = sample.localToGlobal(Offset.zero).dy;
      final delta = index - anchor.index;
      return scroll.position.pixels +
          (sampleTop - viewportTop) -
          delta * sample.size.height +
          anchor.intraOffset;
    }
    return null;
  }

  RenderBox? _titleBox(String id) {
    final title = _titles[id];
    final root = _keys[id]?.currentContext;
    if (title == null || root is! Element) return null;
    RenderBox? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is Text && widget.data == title) {
        final box = element.renderObject;
        if (box is RenderBox && box.attached) found = box;
        return;
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found;
  }

  RenderBox? _rowBox(String id) {
    final box = _keys[id]?.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.size.height > 0 ? box : null;
  }
}

class _AnchorPoint {
  _AnchorPoint({
    required this.id,
    required this.index,
    required this.order,
    required this.intraOffset,
  });

  final String id;
  final int index;
  final List<String> order;

  /// Positive when the title top is above the visible viewport top, negative
  /// when the record starts below it (the list is still above the first row).
  final double intraOffset;
  int approximatePasses = 0;
  int restorePasses = 0;
  int matchedFrames = 0;
}
