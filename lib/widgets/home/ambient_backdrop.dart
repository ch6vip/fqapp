import 'package:flutter/material.dart';

import 'home_design.dart';

/// A quiet wash of warm light. Scrolling moves the contour, not a ticker.
class AmbientBackdrop extends StatelessWidget {
  final ScrollController scroll;

  const AmbientBackdrop({super.key, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: scroll,
          builder: (context, _) => CustomPaint(
            painter: _PaperLightPainter(
              offset: !reducedMotion && scroll.hasClients ? scroll.offset : 0,
              palette: palette,
            ),
          ),
        ),
      ),
    );
  }
}

class _PaperLightPainter extends CustomPainter {
  final double offset;
  final HomePalette palette;

  const _PaperLightPainter({required this.offset, required this.palette});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(palette.canvas, BlendMode.src);
    final center = Offset(size.width * 0.98, 40 - offset.clamp(0, 900) * 0.08);
    final radius = size.width * 0.8;
    if (radius <= 0) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            HomePalette.accent.withValues(alpha: palette.dark ? 0.07 : 0.055),
            HomePalette.accent.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_PaperLightPainter oldDelegate) =>
      offset != oldDelegate.offset || palette.dark != oldDelegate.palette.dark;
}
