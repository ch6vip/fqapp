import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../services/app_theme_style.dart';
import 'app_ui_scope.dart';

/// A semantic scroll anchor: the piece of content the viewport's top edge was
/// sitting on, plus how far into it.
///
/// The classic and archive layouts are different widget trees, so a style
/// switch tears the [Scrollable] (and its [ScrollPosition]) down and the page
/// starts again at offset 0. Reusing a [ScrollController] or a plain [Key] does
/// not change that: a new position starts from the controller's initial
/// offset. Keeping the *content* instead survives the swap — an id both layouts
/// can place (`synopsis`, `directory/chapter:chapter-23`, `works/work:42`) and
/// the offset of its leading edge relative to the viewport.
@immutable
class ContentAnchor {
  const ContentAnchor({
    required this.id,
    required this.offset,
    required this.pixels,
    this.index,
    this.extent = 0,
  });

  /// Content id, e.g. `synopsis` or `directory/chapter:chapter-23`.
  final String id;

  /// How far the anchor's leading edge sat above the layout's *visible* top
  /// edge (below a floating archive header, below a classic AppBar). Negative
  /// when the anchor started below that edge.
  final double offset;

  /// The raw scroll offset when captured. Auxiliary only: lazy lists build the
  /// rows around the viewport, so the new layout may need a first landing near
  /// this offset before the anchor row exists to snap to.
  final double pixels;

  /// Position of the anchored item in the page's own data (chapter/volume/work
  /// index). A lazy layout only builds the rows around the viewport, so when
  /// the row is not mounted yet the index is what lets the restore estimate
  /// where it lives instead of falling back to the section.
  final int? index;

  /// Height of the anchored row in the layout it was captured from. The other
  /// layout may use much shorter rows (a grid card vs a list row), so the same
  /// pixel depth can put the whole row above the viewport; the restore converts
  /// the depth with this value.
  final double extent;

  @override
  String toString() =>
      'ContentAnchor($id, offset: $offset, pixels: $pixels, '
      'index: $index, extent: $extent)';
}

const String _anchorKeyPrefix = 'content-anchor:';

/// Stable key for a content anchor. Both layout branches must use the same id
/// for the same content; a row id may carry its section as a path prefix
/// (`directory/chapter:42`) so [contentAnchorFallbackIds] can fall back to the
/// whole section when the other layout does not show that row.
Key contentAnchorKey(String id) => ValueKey<String>('$_anchorKeyPrefix$id');

/// Layout ids that may stand in for [id]: `directory/chapter:42` falls back to
/// the `directory` section, which both layouts always build.
Iterable<String> contentAnchorFallbackIds(String id) sync* {
  final split = id.lastIndexOf('/');
  if (split > 0) yield id.substring(0, split);
}

/// The offset that puts [box]'s leading edge at the viewport's leading edge.
double? contentAnchorRevealOffset(RenderBox box) {
  final viewport = RenderAbstractViewport.maybeOf(box);
  if (viewport == null) return null;
  return viewport.getOffsetToReveal(box, 0).offset;
}

/// Reads the anchor at [position]'s top edge from `root`'s subtree.
///
/// Every mounted anchor key is measured. The content covering the top edge
/// wins; when the edge falls in the gap *between* two anchors (grid spacing,
/// section margins), the next anchor is used so the same gap survives the
/// swap. Elements are visited in tree order, which is document order for a
/// vertical sliver list.
ContentAnchor? captureContentAnchor(
  BuildContext root,
  ScrollPosition position, {
  int? Function(String anchorId)? indexOf,
  double visibleInset = 0,
}) {
  final anchors = <({String id, double reveal, double extent, int order})>[];
  void visit(Element element) {
    final key = element.widget.key;
    if (key is ValueKey<String> && key.value.startsWith(_anchorKeyPrefix)) {
      final renderObject = element.renderObject;
      if (renderObject is RenderBox &&
          renderObject.attached &&
          renderObject.hasSize) {
        final reveal = contentAnchorRevealOffset(renderObject);
        if (reveal != null) {
          anchors.add((
            id: key.value.substring(_anchorKeyPrefix.length),
            reveal: reveal,
            extent: renderObject.size.height,
            order: anchors.length,
          ));
        }
      }
    }
    element.visitChildElements(visit);
  }

  final element = root as Element;
  visit(element);
  if (anchors.isEmpty) return null;
  // Stable on purpose: cards of one grid row share a reveal, and the capture
  // must pick the same one on every switch.
  anchors.sort((a, b) {
    final byReveal = a.reveal.compareTo(b.reveal);
    return byReveal != 0 ? byReveal : a.order.compareTo(b.order);
  });
  final pixels = position.pixels;
  // Content under a floating header is not what the reader is looking at: the
  // classic shell puts its AppBar above the viewport (inset 0), the archive
  // keeps the scroll under the glass bar (inset = chrome height).
  final visibleTop = pixels + visibleInset;
  ({String id, double reveal, double extent, int order})? covering;
  ({String id, double reveal, double extent, int order})? next;
  for (final anchor in anchors) {
    if (anchor.reveal <= visibleTop + 0.5) {
      covering = anchor;
    } else {
      next = anchor;
      break;
    }
  }
  var chosen = covering ?? next!;
  // The visible top edge falls into the gap after [covering] (a grid row or
  // section margin): keep that gap by anchoring to the next entry instead.
  if (covering != null &&
      next != null &&
      covering.reveal + covering.extent < visibleTop - 0.5) {
    chosen = next;
  }
  return ContentAnchor(
    id: chosen.id,
    offset: visibleTop - chosen.reveal,
    pixels: pixels,
    index: indexOf?.call(chosen.id),
    extent: chosen.extent,
  );
}

/// The row family of an id: `directory/chapter:c7` → `directory/chapter`.
/// Section anchors (`directory`, `works`) have no family.
String? contentAnchorKind(String id) {
  final split = id.indexOf(':');
  return split < 0 ? null : id.substring(0, split);
}

/// The mounted render box for one anchor id, or null when that row is not
/// built (a lazy list only mounts the rows where it has been scrolled) and when
/// this layout never shows it at all.
RenderBox? findContentAnchorBox(BuildContext root, String id) =>
    _findAnchorBox(root, {id});

/// The mounted section that owns [anchor], used only when the other layout
/// really has no place for the anchored row (the classic 目录 preview shows
/// three chapters, so a row from deep inside the archive catalogue has no
/// equivalent there).
RenderBox? findContentAnchorSection(BuildContext root, ContentAnchor anchor) =>
    _findAnchorBox(root, contentAnchorFallbackIds(anchor.id).toSet());

RenderBox? _findAnchorBox(BuildContext root, Set<String> wanted) {
  if (wanted.isEmpty) return null;
  RenderBox? found;
  void visit(Element element) {
    if (found != null) return;
    final key = element.widget.key;
    if (key is ValueKey<String> && key.value.startsWith(_anchorKeyPrefix)) {
      final id = key.value.substring(_anchorKeyPrefix.length);
      if (wanted.contains(id)) {
        final renderObject = element.renderObject;
        if (renderObject is RenderBox &&
            renderObject.attached &&
            renderObject.hasSize) {
          found = renderObject;
          return;
        }
      }
    }
    element.visitChildElements(visit);
  }

  visit(root as Element);
  return found;
}

/// Keeps the scrolled-to content across a classic/archive layout swap.
///
/// Usage from the page that owns [controller] (attach from
/// `State.didChangeDependencies`, detach in `dispose`):
///
/// ```dart
/// @override
/// void didChangeDependencies() {
///   super.didChangeDependencies();
///   _anchors.attach(AppUiScope.maybeOf(context)?.notifier, context);
/// }
/// ```
///
/// [indexOf] returns the data index of an anchored row (chapter/volume/work).
/// A lazy layout only builds the rows around the viewport, so a deep row is
/// usually *not mounted* after the swap even though the new layout will show it
/// once scrolled there. The restore uses that index plus the geometry of the
/// rows that are mounted to land next to the row, then snaps to the exact
/// content id and its old depth. Only an id that never mounts after that
/// (because this layout does not show it at all) falls back to its section.
///
/// The capture runs from the style store's listener: at that moment the
/// outgoing layout is still mounted and laid out, and build has not started
/// (`visitChildElements` is illegal while building).
class ContentAnchorKeeper {
  ContentAnchorKeeper(this.controller, {this.indexOf, this.visibleTopInset});

  final ScrollController controller;

  /// Data index of an anchor id, or null for section anchors.
  final int? Function(String anchorId)? indexOf;

  /// Distance from the scroll viewport's top edge to the first row that is
  /// actually visible in a layout built with [AppThemeStyle].
  ///
  /// The archive shell keeps its scrollable full-screen and paints the glass
  /// header over it (`archiveChromeInset`), while the classic shell puts a
  /// Material AppBar above the body. Both the capture and the restore measure
  /// the depth from that edge, otherwise an archive restore parks the row under
  /// the floating header — mounted, off the visible page, not tappable.
  ///
  /// The capture runs from the store's notification, *before* the tree is
  /// rebuilt, so it must be told which style is on screen: reading the live
  /// scope there would describe the incoming layout and measure the outgoing one
  /// with the wrong chrome.
  final double Function(BuildContext context, AppThemeStyle style)?
  visibleTopInset;

  /// Style the mounted tree was last built with; see [noteLayoutStyle].
  AppThemeStyle? _layoutStyle;

  /// Records the style the current tree was built with. Call from `build`; the
  /// capture then measures the outgoing layout with its own chrome inset.
  void noteLayoutStyle(AppThemeStyle style) => _layoutStyle = style;

  double _inset(BuildContext context, AppThemeStyle style) =>
      visibleTopInset?.call(context, style) ?? 0.0;

  AppThemeStyleStore? _store;
  VoidCallback? _listener;
  ContentAnchor? _pending;
  int _attempts = 0;
  int _snaps = 0;
  int _locates = 0;
  bool _fellBack = false;

  /// Starts measuring when the live style changes. A page without an
  /// [AppUiScope] (theme-token-only tests) keeps its position per layout.
  void attach(AppThemeStyleStore? store, BuildContext context) {
    if (identical(store, _store)) return;
    detach();
    if (store == null) return;
    _store = store;
    void listener() => _capture(context);
    _listener = listener;
    store.addListener(listener);
  }

  void detach() {
    final store = _store;
    final listener = _listener;
    if (store != null && listener != null) store.removeListener(listener);
    _store = null;
    _listener = null;
    _pending = null;
  }

  /// Whether a captured position is still waiting for the new layout.
  bool get isRestoring => _pending != null;

  void _capture(BuildContext context) {
    if (!context.mounted) return;
    // Walking the tree is only legal outside build/layout; a style change that
    // lands mid-frame simply keeps the position the new layout starts with.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.idle &&
        phase != SchedulerPhase.postFrameCallbacks) {
      return;
    }
    final position = controller.hasClients ? controller.position : null;
    if (position == null || !position.hasContentDimensions) return;
    final style = _layoutStyle ?? AppUiScope.of(context);
    final anchor = captureContentAnchor(
      context,
      position,
      indexOf: indexOf,
      visibleInset: _inset(context, style),
    );
    if (anchor == null) return;
    _pending = anchor;
    _attempts = 0;
    _snaps = 0;
    _locates = 0;
    _fellBack = false;
    _schedule(context);
  }

  void _restore(BuildContext context) {
    final anchor = _pending;
    if (anchor == null) return;
    if (!context.mounted) {
      _pending = null;
      return;
    }
    if (!controller.hasClients) {
      _retry(context);
      return;
    }
    final position = controller.position;
    if (!position.hasContentDimensions) {
      _retry(context);
      return;
    }

    final inset = _inset(context, _layoutStyle ?? AppUiScope.of(context));

    // 1. The very content is mounted: put it back at its old depth below the
    //    visible top edge (not the raw viewport edge).
    final box = findContentAnchorBox(context, anchor.id);
    final reveal = box == null ? null : contentAnchorRevealOffset(box);
    if (box != null && reveal != null) {
      final target = reveal + _depthFor(anchor, box.size.height) - inset;
      if ((position.pixels - target).abs() < 1.5 || _snaps >= 3) {
        _pending = null;
        return;
      }
      _moveTo(position, target);
      _snaps++;
      _schedule(context);
      return;
    }

    // 2. This layout shows the row but has not built it yet: estimate where it
    //    lives from the mounted rows of the same kind, then re-measure.
    if (anchor.index != null && _locates < 8) {
      final estimate = _estimateReveal(context, anchor);
      if (estimate != null) {
        final before = position.pixels;
        _moveTo(position, estimate - inset);
        _locates++;
        if ((position.pixels - before).abs() >= 0.5) {
          _schedule(context);
          return;
        }
      }
      // Nothing moved towards it (clamped, or no usable geometry): this layout
      // cannot reach that row, so treat it as not shown here.
      _locates = 8;
    }

    // 3. This layout has no place for the row (the classic 目录 preview only
    //    shows three chapters): fall back to the owning section at the top.
    if (!_fellBack) {
      _fellBack = true;
      final section = findContentAnchorSection(context, anchor);
      final sectionReveal = section == null
          ? null
          : contentAnchorRevealOffset(section);
      if (sectionReveal != null) {
        _moveTo(position, sectionReveal - inset);
        _pending = null;
        return;
      }
    }

    // 4. Nothing mounted to aim at: land on the old offset and retry a few
    //    frames while the new layout builds.
    if (_attempts == 0) _moveTo(position, anchor.pixels);
    _retry(context);
  }

  /// How far above the viewport's top edge the anchor must sit in the new
  /// layout.
  ///
  /// Negative depths are the gap that preceded the anchor: keeping them leaves
  /// the same gap between sections. A positive depth means the anchor started
  /// above the top edge with part of it on screen; row heights differ between
  /// the layouts (a 231dp grid card becomes a 109dp list row), so the depth is
  /// scaled by the new row height and clamped to keep the anchored row's box
  /// intersecting the viewport instead of parking the whole row above it.
  double _depthFor(ContentAnchor anchor, double newExtent) {
    final offset = anchor.offset;
    if (offset <= 0) return offset;
    // Section anchors (no row kind) keep their absolute depth: their height is
    // the whole block, and the same text should stay at the top edge.
    if (contentAnchorKind(anchor.id) == null) return offset;
    final limit = newExtent > 0 ? newExtent - 1 : offset;
    final oldExtent = anchor.extent;
    if (oldExtent <= 0 || newExtent <= 0) {
      return offset < limit ? offset : limit;
    }
    final scaled = offset * (newExtent / oldExtent);
    return scaled < limit ? scaled : limit;
  }

  /// Estimates the scroll offset that puts [anchor]'s row at the viewport top,
  /// from the mounted rows of the same kind (data index → reveal offset).
  double? _estimateReveal(BuildContext context, ContentAnchor anchor) {
    final target = anchor.index;
    final indexOf = this.indexOf;
    final kind = contentAnchorKind(anchor.id);
    if (target == null || indexOf == null || kind == null) return null;
    final rows = <({int index, double reveal, double extent})>[];
    void visit(Element element) {
      final key = element.widget.key;
      if (key is ValueKey<String> && key.value.startsWith(_anchorKeyPrefix)) {
        final id = key.value.substring(_anchorKeyPrefix.length);
        if (contentAnchorKind(id) == kind) {
          final renderObject = element.renderObject;
          if (renderObject is RenderBox &&
              renderObject.attached &&
              renderObject.hasSize) {
            final reveal = contentAnchorRevealOffset(renderObject);
            final index = indexOf(id);
            if (reveal != null && index != null) {
              rows.add((
                index: index,
                reveal: reveal,
                extent: renderObject.size.height,
              ));
            }
          }
        }
      }
      element.visitChildElements(visit);
    }

    visit(context as Element);
    if (rows.isEmpty) return null;
    rows.sort((a, b) => a.index.compareTo(b.index));
    // Extent per data index: the first pair whose reveal differs (a grid row
    // shares one reveal across its columns, so same-reveal neighbours skip).
    double? slope;
    for (var i = 1; i < rows.length; i++) {
      final deltaIndex = rows[i].index - rows[0].index;
      final deltaReveal = rows[i].reveal - rows[0].reveal;
      if (deltaIndex > 0 && deltaReveal.abs() > 0.5) {
        slope = deltaReveal / deltaIndex;
        break;
      }
    }
    slope ??= rows.first.extent;
    if (!slope.isFinite || slope.abs() < 0.5) return null;
    // Base the estimate on the row closest to the target so the error stays
    // inside a row or two: the snap step corrects the rest.
    var base = rows.first;
    for (final row in rows) {
      if ((row.index - target).abs() < (base.index - target).abs()) base = row;
    }
    return base.reveal + (target - base.index) * slope;
  }

  void _schedule(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore(context));
  }

  void _retry(BuildContext context) {
    if (_attempts >= 3) {
      _pending = null;
      return;
    }
    _attempts++;
    _schedule(context);
  }

  void _moveTo(ScrollPosition position, double target) {
    final min = position.minScrollExtent;
    final max = position.maxScrollExtent;
    if (!target.isFinite || !max.isFinite || max < min) return;
    final clamped = target.clamp(min, max).toDouble();
    if ((position.pixels - clamped).abs() < 0.5) return;
    controller.jumpTo(clamped);
  }
}
