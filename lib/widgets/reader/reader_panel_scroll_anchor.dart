import 'package:flutter/widgets.dart';

/// Keeps a list's *content* in place when its renderer changes.
///
/// Classic and archive reader panels mount different scrollables (a bounded
/// [ListView] versus a [CustomScrollView] with a header sliver), so restoring
/// the raw pixel offset puts a different record under the same pixel. This
/// anchor remembers the topmost visible row's stable id and its offset inside
/// the viewport, then re-applies that row position after the new renderer has
/// laid out.
///
/// Rows opt in with [keyFor]; capture walks the mounted keys, so variable row
/// heights (short/long bookmark excerpts, result previews) need no estimates.
class ReaderPanelScrollAnchor {
  ReaderPanelScrollAnchor(this.controller);

  final ScrollController controller;
  final Map<String, GlobalKey> _keys = {};
  String? _id;
  double _delta = 0;
  double? _offset;
  double? _fraction;
  int _revision = 0;
  bool _restoring = false;

  /// Stable key for one row identity. The same id gets the same key in both
  /// renderers, which is also what lets the existing `ValueKey` below it keep
  /// its own tests/accessibility.
  GlobalKey keyFor(String id) => _keys.putIfAbsent(
    id,
    () => GlobalKey(debugLabel: 'reader-panel-row-$id'),
  );

  /// Reads the current row geometry. Must run *after* layout (post-frame or a
  /// scroll update), never from `didChangeDependencies`: the surrounding route
  /// can be inside a LayoutBuilder, where `localToGlobal` hits render objects
  /// that have not been laid out yet. Keeps the previous anchor when no row is
  /// measurable (e.g. an empty result list).
  void capture() {
    if (_restoring || !controller.hasClients) return;
    final position = controller.position;
    final viewport = position.context.storageContext.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return;
    }
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final viewportHeight = viewport.size.height;
    String? bestId;
    var bestTop = double.infinity;
    for (final entry in _keys.entries) {
      final row = entry.value.currentContext?.findRenderObject();
      if (row is! RenderBox || !row.attached || !row.hasSize) continue;
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
    _delta = bestTop;
    _offset = controller.offset;
    final max = position.maxScrollExtent;
    _fraction = max > 0 ? controller.offset / max : null;
  }

  /// Re-applies the captured row position once the new renderer has built.
  ///
  /// First tries the old pixel offset, then (if the row is not mounted there)
  /// the old proportional position, then corrects by the measured row delta.
  /// [fallbackOffset] covers a switch before the first capture. Every step is
  /// guarded by [cancel] and a live controller, and captures pause until the
  /// restore finishes so they cannot overwrite the anchor mid-flight.
  void restore({double? fallbackOffset}) {
    final id = _id;
    final offset = _offset ?? fallbackOffset;
    final fraction = _fraction;
    if (id == null && offset == null) return;
    _restoring = true;
    final revision = ++_revision;

    void schedule(int step) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (revision != _revision) return;
        if (!controller.hasClients) {
          // The new renderer may attach one frame later; retry briefly instead
          // of leaving captures paused forever.
          if (step < 4) {
            schedule(step + 1);
          } else {
            _restoring = false;
          }
          return;
        }
        final position = controller.position;
        if (step == 0) {
          if (offset != null) {
            controller.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
          }
          schedule(1);
          return;
        }
        final row = id == null
            ? null
            : _keys[id]?.currentContext?.findRenderObject();
        final viewport = position.context.storageContext.findRenderObject();
        if (row is RenderBox &&
            row.attached &&
            row.hasSize &&
            viewport is RenderBox &&
            viewport.attached &&
            viewport.hasSize) {
          final top =
              row.localToGlobal(Offset.zero).dy -
              viewport.localToGlobal(Offset.zero).dy;
          final adjust = top - _delta;
          if (adjust.abs() > .5) {
            controller.jumpTo(
              (controller.offset + adjust).clamp(0.0, position.maxScrollExtent),
            );
          }
          _restoring = false;
          return;
        }
        if (step == 1 && fraction != null) {
          controller.jumpTo(
            (fraction.clamp(0.0, 1.0) * position.maxScrollExtent).clamp(
              0.0,
              position.maxScrollExtent,
            ),
          );
          schedule(2);
          return;
        }
        _restoring = false;
      });
    }

    schedule(0);
  }

  /// Drops any pending restore; call from `dispose`.
  void cancel() {
    _revision++;
    _restoring = false;
  }
}
