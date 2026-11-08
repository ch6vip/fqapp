import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Keeps a list's *content* in place when its renderer changes.
///
/// Classic and archive reader panels mount different scrollables (a bounded
/// [ListView] versus a [CustomScrollView] with a header sliver), so restoring
/// the raw pixel offset puts a different record under the same pixel. This
/// anchor remembers the topmost visible row's stable id, its list index and its
/// offset inside the viewport, then re-applies that row position after the new
/// renderer has laid out.
///
/// Rows opt in with [keyFor]; capture walks the mounted keys, so variable row
/// heights (short/long bookmark excerpts, result previews) need no estimates.
class ReaderPanelScrollAnchor {
  ReaderPanelScrollAnchor(this.controller);

  final ScrollController controller;
  final Map<String, GlobalKey> _keys = {};
  final Map<String, int> _order = {};
  String? _id;
  int? _index;
  double _delta = 0;
  double? _offset;
  double? _fraction;
  int _revision = 0;
  bool _restoring = false;

  /// Stable key for one row identity. The same id gets the same key in both
  /// renderers, which is also what lets the existing `ValueKey` below it keep
  /// its own tests/accessibility. [index] is the row's current position in the
  /// data list and drives the directed search when the target row is not built
  /// at the guessed offset.
  GlobalKey keyFor(String id, {int? index}) {
    if (index != null) _order[id] = index;
    return _keys.putIfAbsent(
      id,
      () => GlobalKey(debugLabel: 'reader-panel-row-$id'),
    );
  }

  /// Reads the current row geometry. Must run *after* layout (post-frame or a
  /// scroll update), never from `didChangeDependencies`: the surrounding route
  /// can be inside a LayoutBuilder, where `localToGlobal` hits render objects
  /// that have not been laid out yet. Keeps the previous anchor when no row is
  /// measurable (e.g. an empty result list).
  void capture() {
    if (_restoring || !controller.hasClients) return;
    final position = controller.position;
    final viewport = _viewportBox(position);
    if (viewport == null) return;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final viewportHeight = viewport.size.height;
    String? bestId;
    var bestTop = double.infinity;
    for (final entry in _keys.entries) {
      final row = _rowBox(entry.key);
      if (row == null) continue;
      final top = row.localToGlobal(Offset.zero).dy - viewportTop;
      final bottom = top + row.size.height;
      // First row that intersects the viewport, including a partially
      // scrolled-out top row.
      if (bottom <= 0 || top >= viewportHeight) continue;
      if (top < bestTop) {
        bestTop = top;
        bestId = entry.key;
      }
    }
    if (bestId == null) return;
    _id = bestId;
    _index = _order[bestId];
    _delta = bestTop;
    _offset = controller.offset;
    final max = position.maxScrollExtent;
    _fraction = max > 0 ? controller.offset / max : null;
  }

  /// Re-applies the captured row position once the new renderer has built.
  ///
  /// The old pixel offset and the old proportional position are only first
  /// guesses: the two renderers have different row heights and header slivers,
  /// so the target row is often not built there. When that happens this walks
  /// the list towards the target row's index (one viewport fraction at a time,
  /// so the row cannot be skipped), then corrects the measured in-row offset
  /// and verifies it. Every step is guarded by [cancel] and a live controller.
  void restore({double? fallbackOffset}) {
    final id = _id;
    final offset = _offset ?? fallbackOffset;
    final fraction = _fraction;
    if (id == null && offset == null) return;
    _restoring = true;
    final revision = ++_revision;
    var firstGuess = true;
    var triedFraction = false;
    var attempts = 0;
    var verifications = 0;

    void finish() {
      _restoring = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (revision == _revision) capture();
      });
    }

    void step() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (revision != _revision) return;
        if (!controller.hasClients) {
          // The new renderer may attach one frame later; retry briefly instead
          // of leaving captures paused forever.
          if (attempts++ < 4) {
            step();
          } else {
            finish();
          }
          return;
        }
        final position = controller.position;
        if (firstGuess) {
          firstGuess = false;
          if (offset != null) {
            controller.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
          }
          step();
          return;
        }

        final row = _rowBox(id);
        final rowTop = row == null ? null : _rowTop(row, position);
        if (rowTop != null) {
          final delta = rowTop - _delta;
          if (delta.abs() > .5) {
            controller.jumpTo(
              (controller.offset + delta).clamp(0.0, position.maxScrollExtent),
            );
            // Verify on the next frame that the row really sits where the
            // captured frame had it; a clamped scroll may not get there.
            if (verifications++ < 2) {
              step();
              return;
            }
          } else if (verifications++ < 1) {
            // Re-measure once even when the first guess happened to be exact.
            step();
            return;
          }
          finish();
          return;
        }

        // Target row is not built at the guess. Try the old proportional
        // position once, then search towards the target's list index.
        if (!triedFraction && fraction != null) {
          triedFraction = true;
          controller.jumpTo(
            (fraction.clamp(0.0, 1.0) * position.maxScrollExtent).clamp(
              0.0,
              position.maxScrollExtent,
            ),
          );
          step();
          return;
        }
        if (attempts++ >= 60 || !_searchTowardTarget(position)) {
          finish();
          return;
        }
        step();
      });
    }

    step();
  }

  /// Moves one bounded step towards [_index]. Rows are mounted with their index
  /// in [_order]; the nearest built row tells the direction even when the
  /// target is thousands of pixels away. A step never exceeds one viewport, so
  /// the target row is always built before it can be scrolled past.
  bool _searchTowardTarget(ScrollPosition position) {
    final target = _index;
    if (target == null) return false;
    int? minIndex;
    int? maxIndex;
    for (final entry in _keys.entries) {
      if (entry.value.currentContext == null) continue;
      final index = _order[entry.key];
      if (index == null) continue;
      minIndex = minIndex == null ? index : math.min(minIndex, index);
      maxIndex = maxIndex == null ? index : math.max(maxIndex, index);
    }
    if (minIndex == null || maxIndex == null) return false;
    final direction = target > maxIndex
        ? 1
        : target < minIndex
        ? -1
        : 1;
    final step = math.max(48.0, position.viewportDimension * .6) * direction;
    final next = (controller.offset + step).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((next - controller.offset).abs() < .5) return false;
    controller.jumpTo(next);
    return true;
  }

  RenderBox? _rowBox(String? id) {
    if (id == null) return null;
    final object = _keys[id]?.currentContext?.findRenderObject();
    return object is RenderBox && object.attached && object.hasSize
        ? object
        : null;
  }

  RenderBox? _viewportBox(ScrollPosition position) {
    final object = position.context.storageContext.findRenderObject();
    return object is RenderBox && object.attached && object.hasSize
        ? object
        : null;
  }

  double? _rowTop(RenderBox row, ScrollPosition position) {
    final viewport = _viewportBox(position);
    if (viewport == null) return null;
    return row.localToGlobal(Offset.zero).dy -
        viewport.localToGlobal(Offset.zero).dy;
  }

  /// Drops any pending restore; call from `dispose`.
  void cancel() {
    _revision++;
    _restoring = false;
  }
}
