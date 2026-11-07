// Ported from Wenku8_Flutter (revision ebcd7f1), `lib/native_effects.dart`
// (`NativeGlassMorph`).
//
// Mechanical substitutions:
// - `NativeGlassMorph` -> `WenkuGlassMorph` (the shared UI slice keeps the
//   upstream class name out of fqapp's public surface).
//
// Everything else is copied verbatim.

import 'dart:ui' as ui;

import 'package:flutter/animation.dart';

/// Optical properties follow a menu's growth at scene composition time.
/// The first frame uses the originating control, not an already frosted panel.
class WenkuGlassMorph {
  const WenkuGlassMorph({
    required this.animation,
    required this.radius,
    required this.thickness,
    required this.blur,
  });

  final Animation<double> animation;
  final double radius;
  final double thickness;
  final double blur;

  double get progress =>
      Curves.easeOutCubic.transform(animation.value.clamp(0.0, 1.0));

  double resolve(double source, double target) =>
      ui.lerpDouble(source, target, progress)!;
}
