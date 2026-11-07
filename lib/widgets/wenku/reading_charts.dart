// Upstream source: Wenku8_Flutter rev ebcd7f1
//   lib/reading_statistics_charts.dart (ReadingRhythmChart, _RhythmFrame,
//     _RhythmPainter, readingRhythmPoints/readingRhythmPath, geometry helpers)
//   lib/reading_statistics_shared_charts.dart (ReadingActivityRing,
//     _ActivityRingPainter)
//
// Mechanical substitutions:
// - `appText(context, value)` -> `value` (fqapp ships one Chinese locale).
// - `NovelMotion.settle` -> `WenkuMotion.settle`.
// - `ArchiveDesign`/`ArchiveMotionScope` come from the vendored
//   `lib/widgets/wenku/wenku_archive.dart` / `src/archive_motion.dart`.
// - The crossfade snapshot controller (`_change`, `_previousSnapshot`,
//   `snapshot()`) is not carried over: this statistics route keeps one fixed
//   range, so the measured trace only needs the entrance reveal and the
//   selected-day cursor. Geometry, colors, axis text and semantics are the
//   upstream ones.
// - Class names are kept as upstream (`ReadingRhythmChart`,
//   `ReadingActivityRing`); the integration pass dropped the temporary
//   `Misc` prefix and the `misc_reading_charts.dart` filename.
import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'src/app_text.dart';
import 'wenku_archive.dart';
import 'wenku_theme.dart';

/// A bounded reading trace. Null days deliberately break both curves:
/// absence of a measurement must never look like a measured zero.
class ReadingRhythmChart extends StatelessWidget {
  const ReadingRhythmChart({
    super.key,
    required this.dates,
    required this.minutes,
    required this.averageMinutes,
    required this.selectedIndex,
    required this.onSelected,
    this.entrance,
    this.reduceMotion = false,
  });

  final List<DateTime> dates;
  final List<double?> minutes;
  final List<double?> averageMinutes;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Animation<double>? entrance;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final scope = ArchiveMotionScope.maybeOf(context);
    final reduce =
        reduceMotion ||
        MediaQuery.disableAnimationsOf(context) ||
        (scope != null && !scope.enabled);
    final animation = reduce
        ? const AlwaysStoppedAnimation<double>(1)
        : entrance ??
              scope?.animation ??
              const AlwaysStoppedAnimation<double>(1);
    final count = math.min(dates.length, minutes.length);
    final selected = count == 0 ? 0 : selectedIndex.clamp(0, count - 1);
    final visibleMinutes = minutes.take(count).toList(growable: false);
    final visibleAverages = List<double?>.generate(
      count,
      (i) => i < averageMinutes.length ? averageMinutes[i] : null,
      growable: false,
    );
    final maximum = _axisMaximum([...visibleMinutes, ...visibleAverages]);
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = ArchiveDesign.codeStyle(
      context,
    ).copyWith(fontSize: 10, letterSpacing: 0);
    final selectedValue = count == 0
        ? '尚未记录'
        : '${_dateLabel(dates[selected])}，${_durationLabel(minutes[selected])}';

    void select(int index) {
      if (count == 0) return;
      final next = index.clamp(0, count - 1);
      if (next != selected) onSelected(next);
    }

    return Semantics(
      label: '阅读时长曲线',
      value: selectedValue,
      increasedValue: count > 0 && selected < count - 1
          ? _dateLabel(dates[selected + 1])
          : null,
      decreasedValue: count > 0 && selected > 0
          ? _dateLabel(dates[selected - 1])
          : null,
      onIncrease: count > 0 && selected < count - 1
          ? () => select(selected + 1)
          : null,
      onDecrease: count > 0 && selected > 0 ? () => select(selected - 1) : null,
      child: RepaintBoundary(
        child: SizedBox(
          height: 204,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, 204);
              final bounds = _rhythmBounds(size);
              final frame = _RhythmFrame(
                size: size,
                dates: dates.take(count).toList(growable: false),
                minutes: visibleMinutes,
                averages: visibleAverages,
                maximum: maximum,
                ink: scheme.onSurface,
                muted: scheme.onSurfaceVariant,
                style: labelStyle,
              );
              void selectAt(Offset position) => select(
                count < 2
                    ? 0
                    : ((position.dx - bounds.left) / bounds.width * (count - 1))
                          .round(),
              );

              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey('misc-reading-rhythm-gesture'),
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      onTapUp: count == 0
                          ? null
                          : (details) => selectAt(details.localPosition),
                      onHorizontalDragStart: count == 0
                          ? null
                          : (details) => selectAt(details.localPosition),
                      onHorizontalDragUpdate: count == 0
                          ? null
                          : (details) => selectAt(details.localPosition),
                      child: CustomPaint(
                        painter: _RhythmPainter(
                          frame: frame,
                          entrance: animation,
                          selectedIndex: selected,
                          surface: scheme.surface,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: ExcludeSemantics(
                      child: Row(
                        children: [
                          AppText(
                            '分钟',
                            style: labelStyle,
                            textScaler: TextScaler.noScaling,
                          ),
                          const Spacer(),
                          _TraceLegend(
                            label: '每日',
                            color: scheme.onSurface,
                            style: labelStyle,
                          ),
                          const SizedBox(width: 14),
                          _TraceLegend(
                            label: '7 日均值',
                            color: scheme.onSurfaceVariant,
                            style: labelStyle,
                            dashed: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TraceLegend extends StatelessWidget {
  const _TraceLegend({
    required this.label,
    required this.color,
    required this.style,
    this.dashed = false,
  });

  final String label;
  final Color color;
  final TextStyle style;
  final bool dashed;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 16,
        child: Row(
          children: [
            Expanded(
              child: ColoredBox(color: color, child: const SizedBox(height: 1)),
            ),
            if (dashed) ...[
              const SizedBox(width: 3),
              Expanded(
                child: ColoredBox(
                  color: color,
                  child: const SizedBox(height: 1),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(width: 5),
      AppText(label, style: style, textScaler: TextScaler.noScaling),
    ],
  );
}

Rect _rhythmBounds(Size size) => Rect.fromLTRB(
  math.min(38, size.width * .2),
  32,
  math.max(1, size.width - 7),
  size.height - 28,
);

double? _measurement(double? value) =>
    value == null || !value.isFinite ? null : math.max(0, value);

double _axisMaximum(Iterable<double?> values) {
  final maxValue = values.fold<double>(
    0,
    (current, value) => math.max(current, _measurement(value) ?? 0),
  );
  if (maxValue == 0) return 30;
  if (maxValue <= 1) return 1;
  final power = math
      .pow(10, (math.log(maxValue) / math.ln10).floor())
      .toDouble();
  final factor = maxValue / power;
  return (factor <= 1
          ? 1
          : factor <= 2
          ? 2
          : factor <= 5
          ? 5
          : 10) *
      power;
}

/// Geometry is separated from painting so its bounds remain inexpensive to
/// verify. A missing sample retains its place on the time axis.
List<Offset?> readingRhythmPoints({
  required List<double?> values,
  required Rect bounds,
  required double maximum,
}) => List<Offset?>.generate(values.length, (index) {
  final value = _measurement(values[index]);
  if (value == null) return null;
  return Offset(
    values.length == 1
        ? bounds.center.dx
        : bounds.left + bounds.width * index / (values.length - 1),
    bounds.bottom - bounds.height * (value / maximum).clamp(0, 1),
  );
}, growable: false);

/// Each cubic's control polygon stays between its two real measurements. This
/// shape-preserving interpolation cannot create a peak or a negative duration.
Path readingRhythmPath(List<Offset?> points) {
  final path = Path();
  Offset? previous;
  for (final point in points) {
    if (point == null) {
      previous = null;
      continue;
    }
    if (previous == null) {
      path.moveTo(point.dx, point.dy);
    } else {
      final middle = (previous.dx + point.dx) / 2;
      path.cubicTo(middle, previous.dy, middle, point.dy, point.dx, point.dy);
    }
    previous = point;
  }
  return path;
}

/// All geometry and text layout are retained for the finite paint animation.
/// Selection and clock ticks never rebuild paths or lay out the axis labels.
class _RhythmFrame {
  _RhythmFrame({
    required this.size,
    required this.dates,
    required this.minutes,
    required this.averages,
    required this.maximum,
    required this.ink,
    required this.muted,
    required this.style,
  }) {
    bounds = _rhythmBounds(size);
    points = readingRhythmPoints(
      values: minutes,
      bounds: bounds,
      maximum: maximum,
    );
    line = readingRhythmPath(points);
    average = _dashedPath(
      readingRhythmPath(
        readingRhythmPoints(values: averages, bounds: bounds, maximum: maximum),
      ),
    );
    area = _rhythmArea(points, bounds.bottom);
    isolated = [
      for (var i = 0; i < points.length; i++)
        if (points[i] != null &&
            (i == 0 || points[i - 1] == null) &&
            (i == points.length - 1 || points[i + 1] == null))
          points[i]!,
    ];
  }
  final Size size;
  final List<DateTime> dates;
  final List<double?> minutes;
  final List<double?> averages;
  final double maximum;
  final Color ink;
  final Color muted;
  final TextStyle style;
  late final Rect bounds;
  late final List<Offset?> points;
  late final List<Offset> isolated;
  late final Path line;
  late final Path average;
  late final Path area;

  void paintGuides(Canvas canvas) {
    final grid = Paint()
      ..color = muted.withValues(alpha: .14)
      ..strokeWidth = .6;
    for (var tick = 0; tick <= 2; tick++) {
      final y = bounds.bottom - bounds.height * tick / 2;
      canvas.drawLine(Offset(bounds.left, y), Offset(bounds.right, y), grid);
      _paintText(
        canvas,
        _number(maximum * tick / 2),
        Offset(0, y - 6),
        style,
        maxWidth: bounds.left - 7,
      );
    }
    if (dates.isEmpty) return;
    for (final index in <int>{0, dates.length ~/ 2, dates.length - 1}) {
      final date = dates[index];
      final x = dates.length == 1
          ? bounds.center.dx
          : bounds.left + bounds.width * index / (dates.length - 1);
      _paintText(
        canvas,
        '${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}',
        Offset(x, bounds.bottom + 11),
        style,
        alignment: index == 0
            ? 0
            : index == dates.length - 1
            ? 1
            : .5,
      );
    }
  }
}

class _RhythmPainter extends CustomPainter {
  _RhythmPainter({
    required this.frame,
    required this.entrance,
    required this.selectedIndex,
    required this.surface,
  }) : super(repaint: entrance);

  final _RhythmFrame frame;
  final Animation<double> entrance;
  final int selectedIndex;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    frame.paintGuides(canvas);
    _paintCurrent(canvas);
  }

  void _paintCurrent(Canvas canvas) {
    if (frame.dates.isEmpty) return;
    final bounds = frame.bounds;
    final time = entrance.value.clamp(0.0, 1.0);
    final primary = _phase(time, 0, .78);
    final average = _phase(time, .12, .9);
    final area = _phase(time, .55, 1);
    if (area > 0) {
      canvas.drawPath(
        frame.area,
        Paint()..color = frame.ink.withValues(alpha: .045 * area),
      );
    }
    _withHorizontalReveal(
      canvas,
      bounds,
      average,
      () => canvas.drawPath(
        frame.average,
        Paint()
          ..color = frame.muted.withValues(alpha: .58)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      ),
    );
    _withHorizontalReveal(canvas, bounds, primary, () {
      canvas.drawPath(
        frame.line,
        Paint()
          ..color = frame.ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7
          ..strokeCap = StrokeCap.round,
      );
      for (final point in frame.isolated) {
        canvas.drawCircle(point, 2.3, Paint()..color = frame.ink);
      }
    });
    final cursorAlpha = _phase(time, .68, 1);
    if (cursorAlpha == 0) return;
    final selectedPoint = frame.points[selectedIndex];
    final selectedX = frame.dates.length == 1
        ? bounds.center.dx
        : bounds.left + bounds.width * selectedIndex / (frame.dates.length - 1);
    canvas.drawLine(
      Offset(selectedX, bounds.top),
      Offset(selectedX, bounds.bottom),
      Paint()
        ..color = frame.muted.withValues(alpha: .3 * cursorAlpha)
        ..strokeWidth = .7,
    );
    if (selectedPoint != null) {
      canvas.drawCircle(
        selectedPoint,
        3.7,
        Paint()..color = surface.withValues(alpha: cursorAlpha),
      );
      canvas.drawCircle(
        selectedPoint,
        3.7,
        Paint()
          ..color = frame.ink.withValues(alpha: cursorAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_RhythmPainter old) =>
      frame != old.frame ||
      entrance != old.entrance ||
      selectedIndex != old.selectedIndex ||
      surface != old.surface;
}

/// The dashboard's activity ratio. Percent text is rendered by widgets so the
/// value stays selectable and legible at any text scale.
class ReadingActivityRing extends StatelessWidget {
  const ReadingActivityRing({
    super.key,
    required this.ratio,
    this.size = 190,
    this.reduceMotion = false,
    this.segmented = false,
    this.caption,
  });

  final double? ratio;
  final double size;
  final bool reduceMotion;
  final bool segmented;
  final String? caption;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: ratio ?? 0),
      duration: reduceMotion || MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      curve: WenkuMotion.settle,
      builder: (context, value, _) => CustomPaint(
        painter: _ActivityRingPainter(
          value,
          Theme.of(context).colorScheme.primary,
          Theme.of(context).colorScheme.onSurface,
          segmented,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppText(
                ratio == null ? '—' : '${(ratio! * 100).round()}%',
                style: TextStyle(
                  fontSize: size * .21,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (caption != null)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: AppText(
                    caption!,
                    style: TextStyle(
                      fontSize: size * .045,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ActivityRingPainter extends CustomPainter {
  const _ActivityRingPainter(this.value, this.ink, this.track, this.segmented);

  final double value;
  final Color ink, track;
  final bool segmented;

  @override
  void paint(Canvas canvas, Size size) {
    if (segmented) {
      const count = 36;
      final center = size.center(Offset.zero);
      final radius = size.width * .37;
      final step = math.pi * 2 / count;
      for (var i = 0; i < count; i++) {
        final active = (value * count - i).clamp(0.0, 1.0);
        final thickness = size.width * (.045 + .045 * active);
        final rect = Rect.fromCircle(
          center: center,
          radius: radius + thickness / 2,
        );
        canvas.drawArc(
          rect,
          -math.pi / 2 + i * step + .025,
          step - .05,
          false,
          Paint()
            ..color = Color.lerp(track.withValues(alpha: .12), ink, active)!
            ..style = PaintingStyle.stroke
            ..strokeWidth = thickness,
        );
      }
      canvas.drawCircle(
        center,
        size.width * .285,
        Paint()..color = track.withValues(alpha: .035),
      );
      return;
    }
    final rect = (Offset.zero & size).deflate(size.width * .10);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .09;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2,
      false,
      pen..color = track.withValues(alpha: .09),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * value,
      false,
      pen..color = ink,
    );
  }

  @override
  bool shouldRepaint(_ActivityRingPainter old) =>
      value != old.value ||
      ink != old.ink ||
      track != old.track ||
      segmented != old.segmented;
}

void _paintText(
  Canvas canvas,
  String text,
  Offset position,
  TextStyle style, {
  double alignment = 0,
  double maxWidth = double.infinity,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: maxWidth);
  painter.paint(canvas, position.translate(-painter.width * alignment, 0));
  painter.dispose();
}

Path _dashedPath(Path path) {
  final dashes = Path();
  for (final metric in path.computeMetrics()) {
    for (var distance = 0.0; distance < metric.length; distance += 8) {
      dashes.addPath(
        metric.extractPath(distance, math.min(distance + 4, metric.length)),
        Offset.zero,
      );
    }
  }
  return dashes;
}

Path _rhythmArea(List<Offset?> points, double baseline) {
  final area = Path();
  var run = <Offset?>[];
  for (final point in [...points, null]) {
    if (point != null) {
      run.add(point);
      continue;
    }
    if (run.length > 1) {
      final contour = readingRhythmPath(run)
        ..lineTo(run.last!.dx, baseline)
        ..lineTo(run.first!.dx, baseline)
        ..close();
      area.addPath(contour, Offset.zero);
    }
    run = [];
  }
  return area;
}

double _phase(double value, double start, double end) => Curves.easeOutCubic
    .transform(((value - start) / (end - start)).clamp(0, 1));

void _withHorizontalReveal(
  Canvas canvas,
  Rect bounds,
  double progress,
  VoidCallback paint,
) {
  if (progress == 0) return;
  if (progress == 1) {
    paint();
    return;
  }
  canvas.save();
  canvas.clipRect(
    Rect.fromLTRB(
      bounds.left - 4,
      bounds.top - 5,
      bounds.left + bounds.width * progress,
      bounds.bottom + 5,
    ),
  );
  paint();
  canvas.restore();
}

String _dateLabel(DateTime date) => '${date.year}年${date.month}月${date.day}日';
String _number(double value) => value == value.roundToDouble()
    ? '${value.toInt()}'
    : value.toStringAsFixed(1);
String _durationLabel(double? minutes) => minutes == null || !minutes.isFinite
    ? '尚未记录'
    : _secondsLabel((math.max(0, minutes) * 60).round());
String _secondsLabel(int? seconds) {
  if (seconds == null) return '尚未记录';
  final value = math.max(0, seconds);
  return value < 60 ? '$value秒' : '${value ~/ 60}分钟${value % 60}秒';
}
