import 'package:flutter/material.dart';

/// A relative drag keeps pressing the track from jumping to that position.
/// Semantics provides the same action to keyboard/accessibility users.
class StorySeekBar extends StatefulWidget {
  final double value;
  final bool enabled;
  final bool seeking;
  final ValueChanged<double> onStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onEnd;
  final VoidCallback onCancel;

  /// 贴底细条的轨道/滑块半径。官方横屏底条（cw7.xml：`abt` 轨道 4dip、
  /// `ah6` 滑块 16dip）用 4/8；竖屏沿用原默认 2/3。
  final double trackWidth;
  final double thumbRadius;

  /// 官方播放段=皮肤橙（`bf3.c.l2()` → `#FFFA6725`，截图第二十二轮），
  /// 滑块恒白（`@color/q`）、剩余轨道 `@color/b8`=#4dffffff（`awc`）。
  /// 默认保持原白色系（通用播放器不受影响）。
  final Color progressColor;
  final Color trackColor;
  final Color thumbColor;

  const StorySeekBar({
    super.key,
    required this.value,
    required this.enabled,
    required this.seeking,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
    required this.onCancel,
    this.trackWidth = 2,
    this.thumbRadius = 3,
    this.progressColor = Colors.white,
    this.trackColor = Colors.white24,
    this.thumbColor = Colors.white,
  });

  @override
  State<StorySeekBar> createState() => _StorySeekBarState();
}

class _StorySeekBarState extends State<StorySeekBar> {
  double _downX = 0;
  double _origin = 0;
  double _value = 0;
  bool _dragging = false;

  void _change(double x, double width) {
    _value = (_origin + (x - _downX) / width).clamp(0.0, 1.0);
    widget.onChanged(_value);
  }

  void _adjust(double delta) {
    final value = (widget.value + delta).clamp(0.0, 1.0);
    widget.onStart(widget.value);
    widget.onChanged(value);
    widget.onEnd(value);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '播放进度',
    value: '${(widget.value.clamp(0.0, 1.0) * 100).round()}%',
    increasedValue: '${((widget.value + .05).clamp(0.0, 1.0) * 100).round()}%',
    decreasedValue: '${((widget.value - .05).clamp(0.0, 1.0) * 100).round()}%',
    onIncrease: widget.enabled ? () => _adjust(.05) : null,
    onDecrease: widget.enabled ? () => _adjust(-.05) : null,
    slider: true,
    child: LayoutBuilder(
      builder: (context, constraints) => Listener(
        onPointerDown: (event) {
          _downX = event.localPosition.dx;
          _origin = widget.value;
          _value = _origin;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.enabled
              ? (details) {
                  _dragging = true;
                  widget.onStart(_origin);
                  _change(details.localPosition.dx, constraints.maxWidth);
                }
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (details) =>
                    _change(details.localPosition.dx, constraints.maxWidth)
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (_) {
                  _dragging = false;
                  widget.onEnd(_value);
                }
              : null,
          onHorizontalDragCancel: () {
            if (!_dragging) return;
            _dragging = false;
            widget.onCancel();
          },
          // Consume track taps so they cannot toggle the video underneath.
          onTap: () {},
          child: SizedBox(
            height: 30,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: widget.seeking ? 1 : 0),
              duration: const Duration(milliseconds: 300),
              builder: (context, emphasis, _) => CustomPaint(
                painter: _SeekPainter(
                  widget.value,
                  emphasis,
                  widget.enabled,
                  widget.trackWidth,
                  widget.thumbRadius,
                  widget.progressColor,
                  widget.trackColor,
                  widget.thumbColor,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SeekPainter extends CustomPainter {
  final double value;
  final double emphasis;
  final bool enabled;
  final double trackWidth;
  final double thumbRadius;
  final Color progressColor;
  final Color trackColor;
  final Color thumbColor;
  _SeekPainter(
    this.value,
    this.emphasis,
    this.enabled,
    this.trackWidth,
    this.thumbRadius,
    this.progressColor,
    this.trackColor,
    this.thumbColor,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..strokeWidth = trackWidth + 4 * emphasis
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    final end = Offset(size.width * value.clamp(0.0, 1.0), y);
    line.color = enabled ? progressColor : Colors.white38;
    canvas.drawLine(Offset(0, y), end, line);
    canvas.drawCircle(
      end,
      thumbRadius * (1 + .22 * emphasis),
      line..style = PaintingStyle.fill..color = thumbColor,
    );
  }

  @override
  bool shouldRepaint(_SeekPainter oldDelegate) =>
      value != oldDelegate.value ||
      emphasis != oldDelegate.emphasis ||
      enabled != oldDelegate.enabled ||
      trackWidth != oldDelegate.trackWidth ||
      thumbRadius != oldDelegate.thumbRadius ||
      progressColor != oldDelegate.progressColor ||
      trackColor != oldDelegate.trackColor ||
      thumbColor != oldDelegate.thumbColor;
}
