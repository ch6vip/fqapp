import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../services/app_theme_style.dart';

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
  });

  /// Content id, e.g. `synopsis` or `directory/chapter:chapter-23`.
  final String id;

  /// How far the anchor's leading edge sat above the viewport's top edge.
  /// Negative when the anchor started below the top.
  final double offset;

  /// The raw scroll offset when captured. Auxiliary only: lazy lists build the
  /// rows around the viewport, so the new layout may need a first landing near
  /// this offset before the anchor row exists to snap to.
  final double pixels;

  @override
  String toString() => 'ContentAnchor($id, offset: $offset, pixels: $pixels)';
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
  ScrollPosition position,
) {
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
  ({String id, double reveal, double extent, int order})? covering;
  ({String id, double reveal, double extent, int order})? next;
  for (final anchor in anchors) {
    if (anchor.reveal <= pixels + 0.5) {
      covering = anchor;
    } else {
      next = anchor;
      break;
    }
  }
  var chosen = covering ?? next!;
  // The top edge falls into the gap after [covering] (a grid row or section
  // margin): keep that gap by anchoring to the next entry instead.
  if (covering != null &&
      next != null &&
      covering.reveal + covering.extent < pixels - 0.5) {
    chosen = next;
  }
  return ContentAnchor(
    id: chosen.id,
    offset: pixels - chosen.reveal,
    pixels: pixels,
  );
}

/// The mounted render box for [anchor], trying the id and then its section
/// fallbacks. Null while the row is outside the lazy layout's built range.
///
/// [matchedId] tells the caller whether it got the exact content or only the
/// section that contains it; a section fallback is placed at the top edge, not
/// at the old row's depth inside the section.
({String matchedId, RenderBox box})? findContentAnchorBox(
  BuildContext root,
  ContentAnchor anchor,
) {
  final exact = _findAnchorBox(root, {anchor.id});
  if (exact != null) return (matchedId: anchor.id, box: exact);
  final fallbacks = contentAnchorFallbackIds(anchor.id).toSet();
  final fallback = _findAnchorBox(root, fallbacks);
  if (fallback == null) return null;
  return (matchedId: fallbacks.first, box: fallback);
}

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
/// The capture runs from the style store's listener: at that moment the
/// outgoing layout is still mounted and laid out, and build has not started
/// (`visitChildElements` is illegal while building). The restore runs in a
/// post-frame callback once the incoming layout has laid out, and retries a few
/// frames while a lazy list builds the target rows.
class ContentAnchorKeeper {
  ContentAnchorKeeper(this.controller);

  final ScrollController controller;

  AppThemeStyleStore? _store;
  VoidCallback? _listener;
  ContentAnchor? _pending;
  int _attempts = 0;
  int _snaps = 0;

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
    final anchor = captureContentAnchor(context, position);
    if (anchor == null) return;
    _pending = anchor;
    _attempts = 0;
    _snaps = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore(context));
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
    final match = findContentAnchorBox(context, anchor);
    final reveal = match == null ? null : contentAnchorRevealOffset(match.box);
    if (match != null && reveal != null) {
      // `anchor.offset` is the distance the anchor sat *above* the viewport's
      // top edge, so the target puts it back there: reveal + offset. A section
      // stand-in starts at the top edge instead of inheriting the row's depth.
      final depth = match.matchedId == anchor.id ? anchor.offset : 0.0;
      final target = reveal + depth;
      if ((position.pixels - target).abs() < 1.5) {
        _pending = null;
        return;
      }
      _moveTo(position, target);
      // A lazy sliver estimates the offset of rows it has not built yet, so
      // re-measure once the jump has materialised the neighbourhood.
      if (_snaps >= 3) {
        _pending = null;
        return;
      }
      _snaps++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restore(context));
      return;
    }
    // Lazy layouts only build the rows around the viewport: land near the old
    // offset first, then snap to the content id on a following frame.
    if (_attempts == 0) _moveTo(position, anchor.pixels);
    _retry(context);
  }

  void _retry(BuildContext context) {
    if (_attempts >= 3) {
      _pending = null;
      return;
    }
    _attempts++;
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore(context));
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
