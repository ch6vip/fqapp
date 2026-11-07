// Ported from Wenku8_Flutter lib/archive_shelf_geometry.dart (revision ebcd7f1).
// Verbatim copy; no substitutions.

import 'package:flutter/painting.dart';

/// The loaded solids and their static placeholders use one set of dimensions.
abstract final class ArchiveShelfGeometry {
  // A physical bank, not a full-window banner. Keep the same projection and
  // book proportions on phones, tablets and retained browsing panes.
  static const maxViewportWidth = 520.0;
  static const depthX = .66, depthY = -.30, rowStep = 2.5;
  static double spineFor(double width) => (width * .043).clamp(14.0, 18.0);
  static double pitchFor(double width) => spineFor(width) + 11;
  static double coverFor(double width) => (width * .32).clamp(100.0, 128.0);
  static double bodyHeight(double cover) => (cover - 20) * 166 / 118 + 54;
  static double footprint(double spine, double cover) => spine + cover * depthX;
  static double pullDistance(double cover) => cover * .84;
  static double baseY(double cover, double height) =>
      -cover * depthY + height * .60 + 12;
  static double rowHeight(double cover, double height) =>
      baseY(cover, height) + height + 60;
  static double railY(double distance) {
    final d = distance.clamp(-7.0, 7.0);
    return d * rowStep + d * d * .45;
  }

  static Offset origin(double cover, double height, double weight) {
    final pull = pullDistance(cover) * weight * (1.24 - .24 * weight);
    final lift = weight * weight * (3 - 2 * weight);
    return Offset(
      -pull * depthX,
      baseY(cover, height) - pull * depthY - height * .60 * lift,
    );
  }
}
