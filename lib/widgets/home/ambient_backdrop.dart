import 'package:flutter/material.dart';

import 'home_design.dart';

/// How far the wash is allowed to travel over the whole feed. The contour
/// drifts at [_washDrift] of the scroll offset, so the maximum travel is
/// [_washScrollRange] * [_washDrift].
const double _washScrollRange = 900;
const double _washDrift = 0.08;
const double _maxTravel = _washScrollRange * _washDrift;

/// A quiet wash of warm light. Scrolling moves the contour, not a ticker.
///
/// The wash is painted once into a layer of its own and then only *translated*
/// while the feed scrolls. Re-painting the gradient on every scroll frame
/// costs a full-viewport raster plus a fresh shader allocation per frame, for a
/// picture that never actually changes -- and the feed already repaints its own
/// layer, so the backdrop was doubling the work of every scroll frame.
///
/// The painted layer is grown past the bottom of the viewport so translating it
/// upwards can never expose an unpainted seam at the bottom edge. The page
/// background itself comes from the enclosing [Scaffold], which paints the same
/// [HomePalette.canvas] colour, so the grown area blends in exactly.
class AmbientBackdrop extends StatelessWidget {
  final ScrollController scroll;

  const AmbientBackdrop({super.key, required this.scroll});

  /// How far the contour has drifted for the current scroll offset.
  static double _travel(ScrollController scroll) {
    if (!scroll.hasClients) return 0;
    return scroll.offset.clamp(0.0, _washScrollRange) * _washDrift;
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: -_maxTravel,
            // Outer boundary keeps the per-frame transform out of the feed's
            // own layer; the inner one is the cached wash the transform moves.
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: scroll,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _PaperLightPainter(dark: palette.dark),
                  ),
                ),
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, reducedMotion ? 0 : -_travel(scroll)),
                  child: child,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaperLightPainter extends CustomPainter {
  final bool dark;

  const _PaperLightPainter({required this.dark});

  static final _lightWash = _wash(0.055);
  static final _darkWash = _wash(0.07);

  static RadialGradient _wash(double alpha) => RadialGradient(
    colors: [
      HomePalette.accent.withValues(alpha: alpha),
      HomePalette.accent.withValues(alpha: 0),
    ],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width * 0.8;
    if (radius <= 0) return;
    final center = Offset(size.width * 0.98, 40);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = (dark ? _darkWash : _lightWash).createShader(
          Rect.fromCircle(center: center, radius: radius),
        ),
    );
  }

  @override
  bool shouldRepaint(_PaperLightPainter oldDelegate) => dark != oldDelegate.dark;
}
