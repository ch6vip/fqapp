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
/// A section header is not enough once the user scrolls past it: a list can
/// recycle the header while the rows below it are still on screen, and then
/// there is no anchor at or above the viewport. Rows the user can stop on must
/// carry their own key built from a **stable data id** — for example
/// `_anchor.keyFor('preview-book-${record['id']}')` — so the anchor is found
/// from the content that is actually visible, not from the header.
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

  /// Bumped on every presentation change. A follow-up pass from an older
  /// switch stops as soon as it notices, so a slow display cannot keep an
  /// obsolete anchor fighting the newest one.
  int _generation = 0;

  /// Frame time when the current follow-up pass started.
  Duration? _settleStarted;

  /// Stable key for one section or one content row of the list.
  GlobalKey keyFor(Object id) => _keys.putIfAbsent(id, GlobalKey.new);

  /// Remembers the live presentation. Call once per `build`.
  void track(AppThemeStyle style) {
    if (_disposed) return;
    if (_style != null && _style != style) {
      // Any earlier pass is stale now, even when this switch captures nothing.
      _generation++;
      _appliedPixels = null;
      final captured = _capture();
      _pending = captured;
      if (captured != null) _scheduleRestore();
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
    // keeps changing while the theme animates. Follow the layout until that
    // animation is over; a real user scroll ends the pass immediately.
    _settleStarted = WidgetsBinding.instance.currentFrameTimeStamp;
    _settle(anchor, generation: _generation);
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
    if ((target - position.pixels).abs() >= _tolerance) {
      controller.jumpTo(target);
    }
    // Remember what this pass left on screen. The user-scroll check compares
    // against it, so a no-op pass must update it too instead of leaving a
    // value from an earlier switch behind.
    _appliedPixels = controller.position.pixels;
  }

  /// Follows the layout while the theme animation settles.
  ///
  /// The window is wall-clock time, not a frame count: `MaterialApp` animates
  /// a style change with a 200 ms `AnimatedTheme`, and a fixed 24 frames is
  /// only ~67 ms at 360 Hz, which stops the pass while the layout is still
  /// moving. [generation] ends the pass when a newer switch arrives.
  void _settle(_Anchor anchor, {required int generation}) {
    if (_disposed || generation != _generation) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || generation != _generation) return;
      if (!controller.hasClients) return;
      final pixels = controller.position.pixels;
      final applied = _appliedPixels;
      // Anything other than our own jump means the user scrolled: stop.
      if (applied != null && (pixels - applied).abs() > _userScrollSlop) {
        return;
      }
      _applyAnchor(anchor);
      final started = _settleStarted;
      final elapsed = started == null
          ? _settleWindow
          : WidgetsBinding.instance.currentFrameTimeStamp - started;
      if (elapsed >= _settleWindow) return;
      _settle(anchor, generation: generation);
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

  /// The 200 ms `AnimatedTheme` of `MaterialApp` plus one frame of margin,
  /// measured per frame time stamp so it covers the same animation at 60 and
  /// at 360 Hz.
  static const _settleWindow = Duration(milliseconds: 260);
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
