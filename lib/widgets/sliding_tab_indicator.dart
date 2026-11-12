import 'package:flutter/material.dart';

/// Geometry helpers for tab strips whose underline slides between tabs.
///
/// Three pages need the same thing (home categories, drama channels, shelf
/// tabs), so the rules live here instead of in each page:
///
/// - [centres] lays the tabs out and returns each one's centre x;
/// - [indicatorLeft] puts the underline on a fractional tab position, so it
///   can sit between two tabs while a finger is down;
/// - [indicatorWidth] scales the underline to the tab width (e.g. 50%),
///   with min/max caps so it never gets too thin or too fat;
/// - [position] computes the floating tab index from selected + progress;
/// - [labelWidth] reserves a tab width that does not depend on the selection,
///   so the row never re-flows when the selection moves.
///
/// The last one matters most: a tab whose width follows its selected
/// typography changes width when the selection moves, and the whole row
/// shifts under the finger — the strip visibly jumps on every swipe.
class SlidingTabStrip {
  const SlidingTabStrip._();

  /// The centre of every tab, in the strip's content coordinates.
  ///
  /// [widths] are the reserved tab widths and [gap] the space between them.
  static List<double> centres(List<double> widths, {double gap = 0}) {
    final centres = <double>[];
    var offset = 0.0;
    for (final width in widths) {
      centres.add(offset + width / 2);
      offset += width + gap;
    }
    return centres;
  }

  /// The left edge of an underline of [indicatorWidth] centred on the
  /// floating tab position [position].
  ///
  /// [position] is fractional: 1.5 sits halfway between the second and the
  /// third tab.
  static double indicatorLeft({
    required List<double> centres,
    required double position,
    required double indicatorWidth,
  }) {
    if (centres.isEmpty) return 0;
    final clamped = position.clamp(0.0, (centres.length - 1).toDouble());
    final low = clamped.floor();
    final high = clamped.ceil();
    if (low == high) return centres[low] - indicatorWidth / 2;
    final t = clamped - low;
    final centre = centres[low] + (centres[high] - centres[low]) * t;
    return centre - indicatorWidth / 2;
  }

  /// The floating tab position: the selected tab plus the gesture [progress].
  ///
  /// A progress of 1 means the next tab is fully arrived, so the position is
  /// `index + 1`; 0 keeps it on the selected tab.
  static double position({
    required int index,
    required double progress,
    required int count,
  }) {
    if (count <= 1) return 0;
    return (index + progress).clamp(0.0, (count - 1).toDouble());
  }

  /// The width a tab label needs, measured with [style].
  ///
  /// Measuring with the *selected* style for every tab keeps the row stable:
  /// the selected tab grows its text and the unselected ones shrink theirs,
  /// and without a reserved width the strip would re-flow on every change.
  static double labelWidth({
    required String label,
    required TextStyle style,
    required TextDirection textDirection,
    required TextScaler scaler,
    double horizontalPadding = 0,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: textDirection,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + horizontalPadding;
  }

  /// Underline width that scales with the tab widths at the floating
  /// [position], clamped between [min] and [max].
  ///
  /// When [position] is exactly on one tab the underline is a fixed fraction
  /// of that tab's width; when it sits between two tabs the width lerps
  /// smoothly between them so there's no jump mid-swipe.
  static double indicatorWidth({
    required List<double> widths,
    required double position,
    double ratio = 0.5,
    double min = 16,
    double max = 30,
  }) {
    if (widths.isEmpty) return min;
    final clamped = position.clamp(0.0, (widths.length - 1).toDouble());
    final low = clamped.floor();
    final high = clamped.ceil();
    final lowW = widths[low] * ratio;
    if (low == high) return lowW.clamp(min, max);
    final highW = widths[high] * ratio;
    final t = clamped - low;
    return (lowW + (highW - lowW) * t).clamp(min, max);
  }
}
