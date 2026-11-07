import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// One geometry for the capsule, its gesture gutter and scroll clearance.
abstract final class DockLayout {
  static const itemWidth = 184 / 3;
  static const horizontalInset = 6.0;
  static const iconSize = 20.0;
  static const labelFontSize = 11.0;
  static const labelGap = 3.0;
  static const actionMaxWidth = 620.0;
  static const actionGap = 10.0;
  static const actionSideInset = 24.0;
  static const edgeShadeOpacity = .085;
  static const topEdgeShadeOpacity = .055;
  static double widthFor(int items) => itemWidth * items + horizontalInset * 2;
  static bool get _ios =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// The iOS body leaves a 44pt target inside its six-point vertical padding.
  static double get height => _ios ? 50 : 54;

  /// Short iOS landscapes keep labels beside their icons to preserve content.
  static bool compactOf(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return _ios && size.height < 500 && size.width > size.height;
  }

  /// The visible capsule height for the current orientation.
  static double heightOf(BuildContext context) =>
      compactOf(context) ? 44 : height;

  static double underlayExtentOf(
    BuildContext context, {
    double? contentHeight,
  }) =>
      bottomPaddingOf(context, viewPadding: true) +
      (contentHeight ?? heightOf(context));

  /// iOS reuses the home-indicator gutter instead of adding spacing twice.
  static double bottomPaddingOf(
    BuildContext context, {
    bool viewPadding = false,
  }) {
    final safe = viewPadding
        ? MediaQuery.viewPaddingOf(context).bottom
        : MediaQuery.paddingOf(context).bottom;
    return _ios ? math.max(12, safe) : safe + 12;
  }

  /// Clearance leaves the last row above the dock while preserving Android.
  static double scrollPaddingOf(BuildContext context) => _ios
      ? bottomPaddingOf(context) + heightOf(context) + 20
      : MediaQuery.paddingOf(context).bottom + 120;
}
