import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_preferences.dart';
import 'reader_bookmark_ribbon.dart';
import 'reader_theme.dart';

/// Pull paged text down, or overscroll scrolling text at the chapter's top.
/// The parent owns bookmarks and supplies the saved state of the current page.
/// The reader menu provides the same action without requiring a gesture.
class ReaderBookmarkPull extends StatefulWidget {
  const ReaderBookmarkPull({
    super.key,
    required this.enabled,
    required this.paged,
    required this.preset,
    required this.onAdd,
    required this.child,
    this.isBookmarked = false,
    this.onRemove,
    this.locationKey,
    this.showSavedRibbon = true,
    this.ribbonTextInset = 20,
  });
  final bool enabled;
  final bool paged;
  final ReaderThemePreset preset;
  final Future<void> Function() onAdd;
  final Widget child;

  /// Whether the visible page already has a saved bookmark.
  final bool isBookmarked;

  /// Called when a pull starts on a saved page. Omit to disable deletion.
  final Future<void> Function()? onRemove;

  /// Identifies the current book, chapter, page and source for gesture safety.
  final Object? locationKey;

  /// Disable when the pager already renders its own saved-page ribbon.
  final bool showSavedRibbon;
  final double ribbonTextInset;

  @override
  State<ReaderBookmarkPull> createState() => _ReaderBookmarkPullState();
}

// Flutter reports a cancelled accepted drag through onEnd. Inspect the raw
// cancellation before calling super, so it can never commit an armed bookmark.
class _BookmarkDragRecognizer extends VerticalDragGestureRecognizer {
  VoidCallback? onPointerCancel;

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) onPointerCancel?.call();
    super.handleEvent(event);
  }
}

class _ReaderBookmarkPullState extends State<ReaderBookmarkPull>
    with SingleTickerProviderStateMixin {
  late final AnimationController _return = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 0,
  );
  double _distance = 0;
  double _returnFrom = 0;
  bool _saving = false;
  int? _pointer;
  bool _gestureActive = false;
  bool _removeGesture = false;
  Object? _gestureLocation;
  Future<void> Function()? _gestureAction;
  static const _threshold = 80.0;

  bool get _reduceMotion =>
      widget.preset.isEink || MediaQuery.disableAnimationsOf(context);
  double get _offset => _distance > 0
      ? _distance * 0.7
      // This clock runs from 1 back to 0. A normalized exponential gives a
      // quick initial return and a soft landing, without reversing an ease-out
      // into a slow start followed by an abrupt stop.
      : _returnFrom * ((math.exp(6 * _return.value) - 1) / (math.exp(6) - 1));

  void _begin(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _gestureActive = widget.enabled && !_saving;
    _removeGesture = widget.isBookmarked;
    _gestureLocation = widget.locationKey;
    _gestureAction = _removeGesture ? widget.onRemove : widget.onAdd;
  }

  void _cancel() {
    _gestureActive = false;
    _gestureAction = null;
    _reset();
  }

  void _pointerUp(PointerUpEvent event) {
    if (_pointer != event.pointer) return;
    _pointer = null;
    if (!widget.paged) _end();
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (_pointer != event.pointer) return;
    _pointer = null;
    _cancel();
  }

  void _update(double delta) {
    if (!widget.enabled || _saving || !_gestureActive) return;
    final distance = _distance > 0 ? _distance : _offset / 0.7;
    _return.stop();
    setState(() {
      _returnFrom = 0;
      _distance = (distance + delta).clamp(0, 240);
    });
  }

  void _reset() {
    if (_distance == 0 && !_return.isAnimating) return;
    final from = _offset;
    setState(() {
      _distance = 0;
      _returnFrom = _reduceMotion ? 0 : from;
    });
    if (_returnFrom > 0) _return.reverse(from: 1);
  }

  Future<void> _end() async {
    final action = _gestureAction;
    final commit =
        _gestureActive &&
        widget.enabled &&
        widget.isBookmarked == _removeGesture &&
        widget.locationKey == _gestureLocation &&
        _distance >= _threshold &&
        !_saving;
    _gestureActive = false;
    _gestureAction = null;
    _reset();
    if (!commit || action == null) return;
    _saving = true;
    try {
      await action();
    } finally {
      _saving = false;
    }
  }

  @override
  void didUpdateWidget(ReaderBookmarkPull oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        widget.paged != oldWidget.paged ||
        (widget.isBookmarked != oldWidget.isBookmarked && _gestureActive) ||
        widget.locationKey != oldWidget.locationKey) {
      _gestureActive = false;
      _gestureAction = null;
      _distance = 0;
      _returnFrom = 0;
      _return.stop();
    }
  }

  @override
  void dispose() {
    _return.dispose();
    super.dispose();
  }

  bool _scrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 ||
        !widget.enabled ||
        _saving ||
        notification.metrics.axisDirection != AxisDirection.down) {
      return false;
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        notification.metrics.pixels <= notification.metrics.minScrollExtent &&
        notification.overscroll < 0) {
      _update(-notification.overscroll);
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      if (notification.metrics.pixels < notification.metrics.minScrollExtent) {
        // Bouncing physics report their absolute stretch rather than overscroll.
        final stretch =
            notification.metrics.minScrollExtent - notification.metrics.pixels;
        _update(stretch - _distance);
      } else {
        _reset();
      }
    }
    // Release is handled by the raw pointer, before ballistic scroll updates.
    // ScrollEnd alone must never turn a cancelled/bouncing scroll into a save.
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.paged
        ? RawGestureDetector(
            key: const ValueKey('reader-bookmark-pull'),
            behavior: HitTestBehavior.translucent,
            gestures: widget.enabled
                ? {
                    _BookmarkDragRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          _BookmarkDragRecognizer
                        >(_BookmarkDragRecognizer.new, (recognizer) {
                          recognizer.onPointerCancel = _cancel;
                          recognizer.onUpdate = (event) =>
                              _update(event.delta.dy);
                          recognizer.onEnd = (_) => _end();
                          recognizer.onCancel = _cancel;
                        }),
                  }
                : {},
            child: widget.child,
          )
        : NotificationListener<ScrollNotification>(
            onNotification: _scrollNotification,
            child: widget.child,
          );
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeRight = MediaQuery.paddingOf(context).right;
    final armed = _distance >= _threshold;
    final backing = widget.preset.isEink
        ? Colors.white
        : Color.alphaBlend(
            widget.preset.textColor.withValues(alpha: 0.10),
            widget.preset.backgroundColor,
          );
    final savedRibbon = widget.isBookmarked && widget.showSavedRibbon;
    return Listener(
      onPointerDown: _begin,
      onPointerCancel: _pointerCancel,
      onPointerUp: _pointerUp,
      child: AnimatedBuilder(
        animation: _return,
        builder: (context, _) {
          final offset = _offset;
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  key: const ValueKey('reader-bookmark-backing'),
                  color: backing,
                ),
                if (offset > 12)
                  Positioned(
                    top: safeTop + 12,
                    left: 24,
                    right: safeRight + 56,
                    child: IgnorePointer(
                      child: Semantics(
                        liveRegion: true,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Icon(
                              armed
                                  ? LucideIcons.arrow_up
                                  : LucideIcons.arrow_down,
                              size: 14,
                              color: widget.preset.textColor,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _removeGesture
                                    ? (armed ? '松手删除书签' : '下拉删除书签')
                                    : (armed ? '松手添加书签' : '下拉添加书签'),
                                style: TextStyle(
                                  color: widget.preset.textColor,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Transform.translate(
                  key: const ValueKey('reader-bookmark-content'),
                  offset: Offset(0, offset),
                  child: ColoredBox(
                    color: widget.preset.backgroundColor,
                    child: body,
                  ),
                ),
                if (offset > 0 || savedRibbon)
                  ReaderBookmarkRibbon(
                    key: ValueKey(
                      savedRibbon
                          ? 'reader-bookmark-saved-ribbon'
                          : 'reader-bookmark-pull-ribbon',
                    ),
                    color: widget.preset.selectionAccentColor,
                    height: savedRibbon ? 72 + offset : offset,
                    textInset: widget.ribbonTextInset,
                    semanticLabel: savedRibbon
                        ? '当前页已添加书签'
                        : (_removeGesture ? '删除书签' : '添加书签'),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
