import 'dart:math' as math;

import 'package:flutter/material.dart';

// Drawn to the official geometry rather than copying its drawables.

/// Official `fa3/a`: 2.5dp track (#33 white) and clockwise progress (#E5)
/// from 12 o'clock. Ours tints with the capsule's ink so e-ink stays black.
class RingPainter extends CustomPainter {
  const RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  static const _stroke = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      0,
      0,
      size.width,
      size.height,
    ).deflate(_stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    canvas.drawOval(rect, paint..color = color.withValues(alpha: 0.2));
    if (progress <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      paint..color = color.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(RingPainter old) =>
      old.progress != progress || old.color != color;
}

/// Official loading ring: a transparent-to-opaque sweep turning 4°/frame.
class LoadingRing extends StatefulWidget {
  const LoadingRing({super.key, required this.color, required this.animate});

  final Color color;
  final bool animate;

  @override
  State<LoadingRing> createState() => _LoadingRingState();
}

class _LoadingRingState extends State<LoadingRing>
    with SingleTickerProviderStateMixin {
  // 4° per 60Hz frame is one turn in 1.5s.
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(LoadingRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.animate) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _spin,
    child: CustomPaint(
      size: const Size.square(32),
      painter: SweepPainter(widget.color),
    ),
  );
}

class SweepPainter extends CustomPainter {
  const SweepPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).deflate(1.25);
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..shader = SweepGradient(
          colors: [color.withValues(alpha: 0), color],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(SweepPainter old) => old.color != color;
}

/// Official `csw`: a filled, slightly rounded right-pointing triangle.
class PlayGlyph extends CustomPainter {
  const PlayGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.30, h * 0.18)
      ..lineTo(w * 0.82, h * 0.50)
      ..lineTo(w * 0.30, h * 0.82)
      ..close();
    final paint = Paint()
      ..color = color
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = w * 0.08;
    // Fill, then a round-joined stroke to soften the corners.
    canvas.drawPath(path, paint);
    canvas.drawPath(path, paint..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(PlayGlyph old) => old.color != color;
}

/// Official `cax`: two rounded vertical bars.
class PauseGlyph extends CustomPainter {
  const PauseGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()..color = color;
    final radius = Radius.circular(w * 0.06);
    for (final left in [w * 0.26, w * 0.60]) {
      canvas.drawRRect(
        RRect.fromLTRBR(left, h * 0.20, left + w * 0.14, h * 0.80, radius),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(PauseGlyph old) => old.color != color;
}

/// Official `alh`: a thin round-capped cross.
class CloseGlyph extends CustomPainter {
  const CloseGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..color = color
      ..strokeWidth = w * 0.1
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(w * 0.25, h * 0.25),
      Offset(w * 0.75, h * 0.75),
      paint,
    );
    canvas.drawLine(
      Offset(w * 0.75, h * 0.25),
      Offset(w * 0.25, h * 0.75),
      paint,
    );
  }

  @override
  bool shouldRepaint(CloseGlyph old) => old.color != color;
}
