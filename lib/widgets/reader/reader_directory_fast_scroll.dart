import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../models/media_item.dart';
import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// An overlay handle that follows the official reader's geometry and timing.
class ReaderDirectoryFastScroll extends StatefulWidget {
  const ReaderDirectoryFastScroll({
    super.key,
    required this.controller,
    required this.chapters,
    required this.indexes,
    required this.preset,
    required this.child,
  });

  final ScrollController controller;
  final List<Chapter> chapters;
  final List<int> indexes;
  final ReaderThemePreset preset;
  final Widget child;

  @override
  State<ReaderDirectoryFastScroll> createState() =>
      _ReaderDirectoryFastScrollState();
}

class _ReaderDirectoryFastScrollState extends State<ReaderDirectoryFastScroll>
    with SingleTickerProviderStateMixin {
  // Official asw/d5f: 16x40 visible inside a transparent 32x70 touch area.
  static const _handleWidth = 32.0;
  static const _handleHeight = 70.0;
  static const _scrollIdleDelay = Duration(milliseconds: 1500);
  static const _dragIdleDelay = Duration(milliseconds: 1200);
  final _trackKey = GlobalKey();
  late final AnimationController _opacity;
  Timer? _hideTimer;
  (double, double, double, AxisDirection)? _dimensions;
  int? _dragFrameId;
  double? _pendingOffset;
  bool _dragging = false;
  bool _reduceMotion = false;
  double _grabOffset = 0;

  bool get _instantFade => widget.preset.isEink || _reduceMotion;

  bool get _canScroll {
    if (widget.indexes.length < 2 || !widget.controller.hasClients) {
      return false;
    }
    final position = widget.controller.position;
    return position.hasContentDimensions &&
        position.viewportDimension > _handleHeight &&
        position.maxScrollExtent > position.minScrollExtent;
  }

  @override
  void initState() {
    super.initState();
    _opacity = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    widget.controller.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(ReaderDirectoryFastScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
      _dimensions = null;
    }
    if (oldWidget.indexes != widget.indexes ||
        oldWidget.controller != widget.controller) {
      _dragging = false;
      _cancelDragFrame();
      _hideTimer?.cancel();
      _opacity.value = 0;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _cancelDragFrame();
    _hideTimer?.cancel();
    _opacity.dispose();
    super.dispose();
  }

  void _scheduleHide(Duration delay) {
    _hideTimer?.cancel();
    _hideTimer = Timer(delay, () {
      if (_instantFade) {
        _opacity.value = 0;
      } else {
        _opacity.reverse();
      }
    });
  }

  void _onScroll() {
    if (!_canScroll) {
      _dragging = false;
      _cancelDragFrame();
      _hideTimer?.cancel();
      _opacity.value = 0;
      return;
    }
    if (_instantFade) {
      _opacity.value = 1;
    } else if (_opacity.status != AnimationStatus.forward &&
        _opacity.status != AnimationStatus.completed) {
      _opacity.forward();
    }
    if (!_dragging) _scheduleHide(_scrollIdleDelay);
  }

  bool _onMetrics(ScrollMetricsNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    final dimensions = (
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
      metrics.viewportDimension,
      metrics.axisDirection,
    );
    // Metrics also change when only pixels/extentBefore/extentAfter change.
    // Those notifications must not cancel a live drag or rebuild the wrapper.
    if (_dimensions == dimensions) return false;
    _dimensions = dimensions;
    _dragging = false;
    _cancelDragFrame();
    _onScroll();
    setState(() {});
    return false;
  }

  double? _trackY(Offset global) {
    final box = _trackKey.currentContext?.findRenderObject();
    return box is RenderBox && box.attached
        ? box.globalToLocal(global).dy
        : null;
  }

  void _start(DragDownDetails details, double top) {
    if (!_canScroll) return;
    final y = _trackY(details.globalPosition);
    if (y == null) return;
    _cancelDragFrame();
    _grabOffset = y - top;
    _dragging = true;
    _hideTimer?.cancel();
    // Stop a fling before dragging so the handle cannot move under the finger.
    widget.controller.jumpTo(widget.controller.offset);
    _onScroll();
  }

  void _drag(Offset global, double travel) {
    if (!_dragging || travel <= 0 || !widget.controller.hasClients) return;
    final y = _trackY(global);
    if (y == null) return;
    final position = widget.controller.position;
    if (!position.hasContentDimensions) return;
    final fraction = ((y - _grabOffset) / travel).clamp(0.0, 1.0);
    _pendingOffset =
        position.minScrollExtent +
        fraction * (position.maxScrollExtent - position.minScrollExtent);
    // Keep only the latest pointer position for the next display frame.
    _dragFrameId ??= SchedulerBinding.instance.scheduleFrameCallback((_) {
      _dragFrameId = null;
      _applyPendingOffset();
    });
  }

  void _applyPendingOffset() {
    final offset = _pendingOffset;
    _pendingOffset = null;
    if (!_dragging || offset == null || !_canScroll) return;
    final position = widget.controller.position;
    final target = offset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target != position.pixels) widget.controller.jumpTo(target);
  }

  void _cancelDragFrame() {
    final id = _dragFrameId;
    if (id != null) SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    _dragFrameId = null;
    _pendingOffset = null;
  }

  void _end() {
    if (!_dragging) return;
    _applyPendingOffset();
    _cancelDragFrame();
    _dragging = false;
    _scheduleHide(_dragIdleDelay);
  }

  void _step(bool forward) {
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    if (!position.hasContentDimensions) return;
    widget.controller.jumpTo(
      (position.pixels + (forward ? 1 : -1) * position.viewportDimension).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  int _chapterIndex(double fraction) =>
      widget.indexes[(fraction.clamp(0.0, 1.0) * (widget.indexes.length - 1))
          .round()];

  String _chapterLabel(double fraction) {
    final index = _chapterIndex(fraction);
    return '第 ${index + 1} 章，${widget.chapters[index].title}';
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      return Stack(
        key: _trackKey,
        fit: StackFit.expand,
        children: [
          NotificationListener<ScrollMetricsNotification>(
            onNotification: _onMetrics,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: widget.child,
            ),
          ),
          AnimatedBuilder(
            animation: Listenable.merge([widget.controller, _opacity]),
            builder: (context, child) => _overlay(constraints, child!),
            child: Center(
              child: CustomPaint(
                size: const Size(16, 40),
                painter: _DirectoryHandlePainter(_handleColor),
              ),
            ),
          ),
        ],
      );
    },
  );

  Color get _handleColor => switch (widget.preset) {
    ReaderThemePreset.light => const Color(0xCCD2D2D3),
    ReaderThemePreset.eyeCare => const Color(0xCCB4BDAB),
    ReaderThemePreset.parchment => const Color(0xCCBFB69F),
    ReaderThemePreset.dark => const Color(0xCC5E5E5E),
    ReaderThemePreset.eink => Colors.black,
  };

  Widget _overlay(BoxConstraints constraints, Widget handle) {
    if (!_canScroll || constraints.maxHeight <= _handleHeight) {
      return const SizedBox.shrink();
    }
    final position = widget.controller.position;
    final span = position.maxScrollExtent - position.minScrollExtent;
    final fraction = ((position.pixels - position.minScrollExtent) / span)
        .clamp(0.0, 1.0);
    final pageFraction = position.viewportDimension / span;
    final travel = constraints.maxHeight - _handleHeight;
    final top = fraction * travel;
    return PositionedDirectional(
      end: 0,
      top: top,
      width: _handleWidth,
      height: _handleHeight,
      child: IgnorePointer(
        ignoring: _opacity.isDismissed,
        child: ExcludeSemantics(
          excluding: _opacity.isDismissed,
          child: Semantics(
            label: '快速滚动章节',
            value: _chapterLabel(fraction),
            increasedValue: fraction < 1
                ? _chapterLabel(fraction + pageFraction)
                : null,
            decreasedValue: fraction > 0
                ? _chapterLabel(fraction - pageFraction)
                : null,
            slider: true,
            onIncrease: fraction < 1 ? () => _step(true) : null,
            onDecrease: fraction > 0 ? () => _step(false) : null,
            child: Opacity(
              opacity: _opacity.value,
              child: GestureDetector(
                key: const ValueKey('reader-directory-fast-scroll'),
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                dragStartBehavior: DragStartBehavior.down,
                onVerticalDragDown: (details) => _start(details, top),
                onVerticalDragStart: (details) =>
                    _drag(details.globalPosition, travel),
                onVerticalDragUpdate: (details) =>
                    _drag(details.globalPosition, travel),
                onVerticalDragEnd: (_) => _end(),
                onVerticalDragCancel: _end,
                child: handle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectoryHandlePainter extends CustomPainter {
  const _DirectoryHandlePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The official arrows are transparent cutouts, not a second foreground.
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      )
      ..moveTo(8, 15)
      ..lineTo(10, 18)
      ..lineTo(6, 18)
      ..close()
      ..moveTo(6, 22)
      ..lineTo(10, 22)
      ..lineTo(8, 25)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DirectoryHandlePainter oldDelegate) =>
      color != oldDelegate.color;
}
