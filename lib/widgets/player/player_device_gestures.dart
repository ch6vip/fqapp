import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/player_device_controls.dart';

/// Only adds vertical adjustment gestures in landscape fullscreen. Keeping the
/// supplied child outside the feedback builder preserves the video subtree.
class PlayerDeviceGestures extends StatefulWidget {
  final bool active;
  final bool enabled;
  final Object? interactionKey;
  final Widget child;

  const PlayerDeviceGestures({
    super.key,
    required this.active,
    required this.enabled,
    required this.interactionKey,
    required this.child,
  });

  @override
  State<PlayerDeviceGestures> createState() => _PlayerDeviceGesturesState();
}

class _PlayerDeviceGesturesState extends State<PlayerDeviceGestures>
    with WidgetsBindingObserver {
  final _devices = PlayerDeviceControls();
  final _feedback = ValueNotifier<_AdjustmentFeedback?>(null);
  _AdjustmentDrag? _drag;
  Timer? _hideFeedback;
  bool _foreground = true;

  bool get _enabled => widget.active && widget.enabled && _foreground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didUpdateWidget(PlayerDeviceGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled || oldWidget.interactionKey != widget.interactionKey) {
      _cancelDrag();
    }
    if (oldWidget.active && !widget.active) _resetDevices();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    setState(() => _foreground = foreground);
    if (!foreground) {
      _cancelDrag();
      _resetDevices();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideFeedback?.cancel();
    _drag = null;
    _resetDevices();
    _feedback.dispose();
    super.dispose();
  }

  void _resetDevices() => unawaited(_devices.reset().catchError((Object _) {}));

  bool _current(_AdjustmentDrag drag) =>
      mounted && _enabled && identical(_drag, drag);

  Future<void> _start(DragStartDetails details, double width) async {
    if (!_enabled) return;
    _hideFeedback?.cancel();
    final drag = _drag = _AdjustmentDrag(
      details.localPosition.dx < width / 2
          ? PlayerAdjustment.brightness
          : PlayerAdjustment.volume,
    );
    _feedback.value = _AdjustmentFeedback(drag.adjustment);
    try {
      // Refresh on every gesture so hardware volume buttons are respected.
      final levels = await _devices.read();
      if (!_current(drag) || drag.ended || levels == null) return;
      final base = drag.adjustment == PlayerAdjustment.brightness
          ? levels.brightness
          : levels.volume;
      drag.value = (base + drag.pendingDelta).clamp(drag.minimum, 1.0);
      _feedback.value = _AdjustmentFeedback(drag.adjustment, value: drag.value);
      if (drag.pendingDelta != 0) _queueWrite(drag);
    } catch (_) {
      _failed(drag);
    }
  }

  void _update(DragUpdateDetails details, double height) {
    final drag = _drag;
    if (drag == null || !_current(drag) || drag.ended || height <= 0) return;
    final delta = -details.delta.dy / height * 1.5;
    if (drag.value == null) {
      drag.pendingDelta += delta;
      return;
    }
    drag.value = (drag.value! + delta).clamp(drag.minimum, 1.0);
    _feedback.value = _AdjustmentFeedback(drag.adjustment, value: drag.value);
    _queueWrite(drag);
  }

  void _queueWrite(_AdjustmentDrag drag) {
    drag.pendingValue = drag.value;
    if (!drag.writing) unawaited(_write(drag));
  }

  Future<void> _write(_AdjustmentDrag drag) async {
    drag.writing = true;
    try {
      // At most one platform write in flight; fast moves replace its successor.
      while (_current(drag) && drag.pendingValue != null) {
        final value = drag.pendingValue!;
        drag.pendingValue = null;
        final actual = await _devices.setLevel(drag.adjustment, value);
        if (_current(drag) &&
            drag.pendingValue == null &&
            actual != null &&
            _feedback.value != null) {
          _feedback.value = _AdjustmentFeedback(drag.adjustment, value: actual);
        }
      }
    } catch (_) {
      _failed(drag);
    } finally {
      drag.writing = false;
    }
  }

  void _finish() {
    final drag = _drag;
    if (drag == null) return;
    drag.ended = true;
    if (drag.value == null) {
      // A finger released before the initial read must not adjust later.
      _cancelDrag();
    } else {
      _scheduleFeedbackHide();
    }
  }

  void _cancelDrag() {
    _drag = null;
    _hideFeedback?.cancel();
    _feedback.value = null;
  }

  void _failed(_AdjustmentDrag drag) {
    if (!_current(drag)) return;
    _drag = null;
    _feedback.value = _AdjustmentFeedback(drag.adjustment, failed: true);
    _resetDevices();
    _scheduleFeedbackHide();
  }

  void _scheduleFeedbackHide() {
    _hideFeedback?.cancel();
    _hideFeedback = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) _feedback.value = null;
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _enabled
              ? (details) => unawaited(_start(details, constraints.maxWidth))
              : null,
          onVerticalDragUpdate: _enabled
              ? (details) => _update(details, constraints.maxHeight)
              : null,
          onVerticalDragEnd: _enabled ? (_) => _finish() : null,
          onVerticalDragCancel: _enabled ? _cancelDrag : null,
          child: widget.child,
        ),
        IgnorePointer(
          child: Center(
            child: ValueListenableBuilder<_AdjustmentFeedback?>(
              valueListenable: _feedback,
              builder: (context, feedback, child) {
                if (feedback == null) return const SizedBox.shrink();
                final brightness =
                    feedback.adjustment == PlayerAdjustment.brightness;
                final label = brightness ? '亮度' : '音量';
                return RepaintBoundary(
                  child: Container(
                    key: const ValueKey('player-device-feedback'),
                    margin: const EdgeInsets.all(24),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          brightness
                              ? Icons.brightness_6
                              : Icons.volume_up_rounded,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            feedback.failed
                                ? '暂时无法调节$label'
                                : feedback.value == null
                                ? '$label…'
                                : '$label ${(feedback.value! * 100).round()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    ),
  );
}

class _AdjustmentDrag {
  final PlayerAdjustment adjustment;
  double pendingDelta = 0;
  double? value;
  double? pendingValue;
  bool writing = false;
  bool ended = false;

  _AdjustmentDrag(this.adjustment);

  double get minimum => adjustment == PlayerAdjustment.brightness ? .05 : 0;
}

class _AdjustmentFeedback {
  final PlayerAdjustment adjustment;
  final double? value;
  final bool failed;

  const _AdjustmentFeedback(this.adjustment, {this.value, this.failed = false});
}
