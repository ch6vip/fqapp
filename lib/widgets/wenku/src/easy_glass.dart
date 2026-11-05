import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

/// The package owns the live backdrop rendering; the app continues to own
/// gestures, layout and menu motion. No screen capture or adaptive readback.
class EasyGlassSurface extends StatelessWidget {
  static bool _reportedRenderer = false;
  const EasyGlassSurface({
    super.key,
    required this.child,
    required this.radius,
    required this.thickness,
    required this.blur,
    required this.refractiveIndex,
    required this.tint,
    required this.emission,
    required this.activation,
    this.independent = false,
    this.physicalOptics = false,
  });

  final Widget child;
  final double radius;
  final double thickness;
  final double blur;
  final double refractiveIndex;
  final ui.Color tint;
  final double emission;
  final double activation;
  final bool independent;
  final bool physicalOptics;

  @override
  Widget build(BuildContext context) {
    if (const bool.fromEnvironment('GLASS_RENDER_DIAGNOSTIC') &&
        !_reportedRenderer) {
      _reportedRenderer = true;
      debugPrint(
        'GLASS_RENDER_PATH shader_filter_supported='
        '${ui.ImageFilter.isShaderFilterSupported}',
      );
    }
    final lens = LiquidGlassLens(
      physicalOptics: physicalOptics,
      style: LiquidGlassStyle(
        shape: LiquidGlassShape.roundedRectangle(cornerRadius: radius),
        // Keep the established clear, slightly milky material. Neither the
        // package's default bright rim nor its coloured fringe belongs here.
        specular: const LiquidGlassLight.specular(intensity: 0, thickness: 0),
        glow: const LiquidGlassLight.glow(intensity: 0, thickness: 0),
        dispersion: 0,
        refractionIndex:
            1 + (refractiveIndex - 1) * .055 + activation.clamp(0, 1) * .006,
        refractionWidth: thickness,
        blur: blur,
        color: ui.Color.alphaBlend(
          const ui.Color(0xffffffff).withValues(alpha: emission.clamp(0, .05)),
          tint,
        ),
      ),
      // Nested controls share ONE read of the finished parent surface. A fresh
      // batch keeps them off the parent's pre-glass input without making every
      // button in a scrolling sheet take a separate backdrop copy.
      child: physicalOptics ? null : LiquidGlassBatch(child: child),
    );
    final surface = physicalOptics
        ? Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(child: lens),
              LiquidGlassBatch(child: child),
            ],
          )
        : lens;
    // Activation changes batching, not subtree identity. Replacing this
    // wrapper would dispose an active TextField at the end of its jelly motion.
    return LiquidGlassBatch.inherit(enabled: !independent, child: surface);
  }
}

/// Native Gaussian + an in-layer alpha ramp. No runtime-filter texture UVs:
/// the engine owns cropped input bounds, edge tiling and device transforms.
class EasyScrollEdge extends StatelessWidget {
  const EasyScrollEdge({
    super.key,
    required this.blur,
    required this.plateau,
    required this.fromBottom,
    required this.child,
  });

  final double blur, plateau;
  final bool fromBottom;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      Positioned.fill(
        // Each edge masks its own blur output. Sharing with page controls or
        // the opposite edge can let dstIn erase the wrong compositing plane.
        child: LiquidGlassBatch.exclude(
          child: LayoutBuilder(
            builder: (context, constraints) => LiquidGlassScrollEdge(
              edge: fromBottom ? LiquidGlassEdge.bottom : LiquidGlassEdge.top,
              color: const ui.Color(0x00000000),
              adaptivity: LiquidGlassAdaptivity.none,
              blur: blur,
              blurCurve: _ScrollEdgeFade(
                constraints.maxHeight > 0
                    ? (plateau / constraints.maxHeight).clamp(0.0, .99)
                    : 0,
              ),
            ),
          ),
        ),
      ),
      child,
    ],
  );
}

class _ScrollEdgeFade extends Curve {
  const _ScrollEdgeFade(this.plateau);
  final double plateau;

  @override
  double transformInternal(double t) {
    final x = ((t - plateau) / (1 - plateau)).clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }

  @override
  bool operator ==(Object other) =>
      other is _ScrollEdgeFade && other.plateau == plateau;
  @override
  int get hashCode => plateau.hashCode;
}
