// Upstream source: Wenku8_Flutter rev ebcd7f1
//   lib/reading_statistics_charts.dart (ReadingActivityCalendar,
//     _CalendarLayout, _CalendarWeekSpan, _CalendarFrame appearances,
//     _CalendarPainter)
// Mechanical substitutions:
// - The upstream painter is rebuilt as positioned widgets with the same
//   geometry (14-week segments, 2 px gap, 2 px cell radius, monochrome fill
//   levels [.055, .18, .31, .49, .72]) so each day keeps an accessible tap
//   target and a stable `reading-heatmap-cell-N` key for the existing
//   regression suite.
// - Cell appearance follows `_CalendarFrame`: a value that exists in the day
//   map is "recorded" (a recorded zero still gets the .055 first level and no
//   outline), while a day with no map entry is "unobserved" (transparent fill
//   plus the .19 muted outline).
// - Selection is the upstream `rectAt(index).inflate(1.4)` RRect stroke with
//   radius 3.4, drawn outside the cell and never changing its fill.
// - `appText(context, value)` -> `value` (single Chinese locale).
// - Selection and entrance crossfades collapse to a direct repaint; the
//   selected-day ring and the readout below the grid are the upstream ones.
// - Range is fqapp's 16-week window (`readingHeatmapDates`), which is the
//   only history span fqapp stores; no upstream range picker is synthesised.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/reading_stats.dart';
import '../wenku/wenku_ui.dart';

/// 阅读日历：上游的周行点阵。每段最多 14 周，分段从左到右排列并在窄屏上
/// 换行；点一格在图下方显示那天的时长，默认显示今天。
class MineHeatmap extends StatefulWidget {
  final ReadingStats stats;
  final DateTime today;

  const MineHeatmap({super.key, required this.stats, required this.today});

  @override
  State<MineHeatmap> createState() => _MineHeatmapState();
}

class _MineHeatmapState extends State<MineHeatmap> {
  DateTime? _picked;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  static const _levels = [.055, .18, .31, .49, .72];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = DateUtils.dateOnly(widget.today);
    final dates = readingHeatmapDates(today);
    final shown = _picked ?? today;
    final minutes = widget.stats.minutesOn(shown);
    final maximum = dates.fold<double>(
      0,
      (value, day) => math.max(value, widget.stats.minutesOn(day)),
    );
    final muted = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '阅读日历', code: '02 / CONSISTENCY'),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final layout = _CalendarLayout(dates.length, constraints.maxWidth);
            return SizedBox(
              height: layout.size.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final segment in layout.segments)
                    for (var weekday = 0; weekday < 7; weekday++)
                      Positioned(
                        left:
                            segment.bounds.left +
                            layout.segmentInset +
                            (weekday + .5) * layout.columnPitch -
                            6,
                        top: segment.bounds.top,
                        width: 12,
                        child: Text(
                          _weekdays[weekday],
                          textAlign: TextAlign.center,
                          textScaler: TextScaler.noScaling,
                          style: ArchiveDesign.codeStyle(
                            context,
                          ).copyWith(fontSize: 9.5),
                        ),
                      ),
                  for (var index = 0; index < dates.length; index++)
                    Positioned(
                      left: layout.rectAt(index).left,
                      top: layout.rectAt(index).top,
                      width: layout.cell,
                      height: layout.cell,
                      child: _cell(scheme, dates[index], index, shown, maximum),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        AppText(
          '${_dayLabel(shown, today)} · '
          '${minutes > 0 ? formatReadingDuration(minutes) : '未阅读'}',
          key: const ValueKey('reading-heatmap-day'),
          style: muted,
        ),
      ],
    );
  }

  Widget _cell(
    ColorScheme scheme,
    DateTime date,
    int index,
    DateTime shown,
    double maximum,
  ) {
    final minutes = widget.stats.minutesOn(date);
    final recorded = widget.stats.dayMinutes.containsKey(readingDayKey(date));
    final level = minutes <= 0 || maximum <= 0
        ? 0
        : (minutes / maximum * 4).ceil().clamp(1, 4);
    final fill = recorded ? _levels[level] : 0.0;
    final selected = date == shown;
    return Semantics(
      label:
          '${date.year}年${date.month}月${date.day}日，'
          '${minutes > 0 ? formatReadingDuration(minutes) : '未阅读'}',
      button: true,
      selected: selected,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('reading-heatmap-cell-$index'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _picked = date),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: recorded
                    ? scheme.onSurface.withValues(alpha: fill)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
                border: recorded
                    ? null
                    : Border.all(
                        color: scheme.onSurfaceVariant.withValues(alpha: .19),
                        width: .7,
                      ),
              ),
            ),
            if (selected)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _SelectionRingPainter(scheme.onSurface),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Upstream `_CalendarPainter`'s selection ring: `rectAt(index).inflate(1.4)`
/// with radius 3.4 and a 1 px ink stroke, painted over the untouched cell.
class _SelectionRingPainter extends CustomPainter {
  const _SelectionRingPainter(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).inflate(1.4),
        const Radius.circular(3.4),
      ),
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_SelectionRingPainter old) => old.ink != ink;
}

/// One week-row dot matrix, arranged in consecutive sections of at most 14
/// weeks. Sections flow left to right, then wrap at the actual widget width.
class _CalendarLayout {
  _CalendarLayout(this.count, double width) {
    final availableWidth = width.isFinite ? math.max(0.0, width) : 520.0;
    rows = (count / 7).ceil();
    final segmentCount = (rows / maximumWeeksPerSegment).ceil();
    final capacity = availableWidth >= 440
        ? 4
        : availableWidth >= 240
        ? 2
        : 1;
    segmentColumns = math.min(capacity, math.max(1, segmentCount));
    final segmentWidth =
        (availableWidth - (segmentColumns - 1) * segmentGap) / segmentColumns;
    final gridWidth = math.max(0.0, segmentWidth);
    columnPitch = math.min(24.0, gridWidth / 7);
    cell = math.min(10.0, math.max(0.0, columnPitch - gap));
    rowPitch = cell + gap;
    segmentInset = (gridWidth - columnPitch * 7) / 2;
    final blocks = <_CalendarSegment>[];
    var top = 0.0;
    for (var start = 0; start < segmentCount; start += segmentColumns) {
      var rowHeight = 0.0;
      for (var column = 0; column < segmentColumns; column++) {
        final index = start + column;
        if (index >= segmentCount) break;
        final firstWeek = index * maximumWeeksPerSegment;
        final weeks = math.min(maximumWeeksPerSegment, rows - firstWeek);
        final height = headerHeight + weeks * rowPitch - gap + bottomPadding;
        blocks.add(
          _CalendarSegment(
            firstWeek,
            Rect.fromLTWH(
              column * (segmentWidth + segmentGap),
              top,
              segmentWidth,
              height,
            ),
          ),
        );
        rowHeight = math.max(rowHeight, height);
      }
      top += rowHeight;
      if (start + segmentColumns < segmentCount) top += segmentGap;
    }
    segments = blocks;
    size = Size(availableWidth, top);
  }

  static const gap = 2.0;
  static const maximumWeeksPerSegment = 14;
  static const segmentGap = 16.0;
  static const bottomPadding = 2.0;
  static const headerHeight = 20.0;

  final int count;
  late final int rows, segmentColumns;
  late final List<_CalendarSegment> segments;
  late final double cell, columnPitch, rowPitch, segmentInset;
  late final Size size;

  Rect rectAt(int index) {
    final week = index ~/ 7;
    final segment = segments[week ~/ maximumWeeksPerSegment];
    return Rect.fromLTWH(
      segment.bounds.left +
          segmentInset +
          index % 7 * columnPitch +
          (columnPitch - cell) / 2,
      segment.bounds.top + headerHeight + (week - segment.firstWeek) * rowPitch,
      cell,
      cell,
    );
  }
}

class _CalendarSegment {
  const _CalendarSegment(this.firstWeek, this.bounds);

  final int firstWeek;
  final Rect bounds;
}

String _dayLabel(DateTime day, DateTime today) {
  if (day == today) return '今天';
  if (day == DateTime(today.year, today.month, today.day - 1)) return '昨天';
  return '${day.month}月${day.day}日';
}
