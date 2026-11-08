import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../services/app_theme_style.dart';

/// Keeps a secondary settings list on the same visible section when the live
/// presentation changes the page gutter, the heading heights or the shell.
///
/// The page keeps **one** [ScrollController] and one list for both
/// presentations, so the scroll position normally survives the switch. This
/// helper additionally remembers which keyed section was at the viewport top
/// and how far it had scrolled past it, and re-applies that anchor after the
/// new layout — a plain pixel offset would drift by the height difference of
/// the widgets above it (archive masthead text vs classic section header).
///
/// Usage:
/// - `final _scroll = ScrollController();`
/// - `final _anchor = SettingsScrollAnchor(_scroll);`
/// - in `build`: `_anchor.track(AppUiScope.of(context));`
/// - wrap each major section in `KeyedSubtree(key: _anchor.keyFor('preview'), …)`
/// - pass `controller: _scroll` to the one list.
///
/// Capture runs during `build` (the previous layout is still on screen);
/// restore runs once after the new tree has been laid out.
class SettingsScrollAnchor {
  SettingsScrollAnchor(this.controller);

  final ScrollController controller;

  final Map<Object, GlobalKey> _keys = {};
  AppThemeStyle? _style;
  _Anchor? _pending;
  bool _restoreScheduled = false;
  bool _disposed = false;
  double? _appliedPixels;

  /// Stable key for one section of the list.
  GlobalKey keyFor(Object id) => _keys.putIfAbsent(id, GlobalKey.new);

  /// Remembers the live presentation. Call once per `build`.
  void track(AppThemeStyle style) {
    if (_disposed) return;
    if (_style != null && _style != style) {
      final captured = _capture();
      if (captured != null) {
        _pending = captured;
        _scheduleRestore();
      }
    }
    _style = style;
  }

  /// Cancels a pending restore. The page disposes it together with its
  /// [ScrollController].
  void dispose() {
    _disposed = true;
    _pending = null;
  }

  void _scheduleRestore() {
    if (_restoreScheduled) return;
    _restoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreScheduled = false;
      _restore();
    });
  }

  _Anchor? _capture() {
    if (!controller.hasClients) return null;
    final position = controller.position;
    if (!position.hasPixels || !position.hasContentDimensions) return null;
    final pixels = position.pixels;
    _Anchor? best;
    for (final anchor in _keys.entries) {
      final offset = _offsetOf(anchor.value);
      if (offset == null || offset > pixels + _tolerance) continue;
      if (best == null || offset >= best.offset) {
        best = _Anchor(anchor.key, offset, pixels - offset);
      }
    }
    return best;
  }

  void _restore() {
    final anchor = _pending;
    _pending = null;
    if (_disposed || anchor == null || !controller.hasClients) return;
    _applyAnchor(anchor);
    // The presentation switch also starts the archive entrance animation and
    // lerps `ContentPanel`'s inner padding, so the height above the anchor
    // keeps changing for a few frames. Follow the layout while it settles;
    // a real user scroll ends the follow-up pass.
    _settle(anchor, frames: _settleFrames);
  }

  void _applyAnchor(_Anchor anchor) {
    if (_disposed || !controller.hasClients) return;
    final position = controller.position;
    if (!position.hasContentDimensions) return;
    final offset = _offsetOf(_keys[anchor.id]);
    if (offset == null) return;
    final target = (offset + anchor.delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < _tolerance) return;
    controller.jumpTo(target);
    _appliedPixels = target;
  }

  void _settle(_Anchor anchor, {required int frames}) {
    if (_disposed || frames <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !controller.hasClients) return;
      final pixels = controller.position.pixels;
      final applied = _appliedPixels;
      // Anything other than our own jump means the user scrolled: stop.
      if (applied != null && (pixels - applied).abs() > _userScrollSlop) {
        return;
      }
      _applyAnchor(anchor);
      _settle(anchor, frames: frames - 1);
    });
    // Keep frames coming for the settle pass even if nothing else animates.
    WidgetsBinding.instance.scheduleFrame();
  }

  double? _offsetOf(GlobalKey? key) {
    final context = key?.currentContext;
    if (context == null) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    return viewport.getOffsetToReveal(box, 0).offset;
  }

  static const _tolerance = 0.5;
  static const _userScrollSlop = 1.0;
  static const _settleFrames = 24;
}

class _Anchor {
  const _Anchor(this.id, this.offset, this.delta);

  final Object id;

  /// Scroll offset that aligns this section's leading edge with the viewport
  /// top, in the layout the page was showing when the style changed.
  final double offset;

  /// How far the viewport had scrolled past that section.
  final double delta;
}
