// Legacy presentation from issue #288, fqapp-backup@f329399.
// Reads the current application stores; no legacy data or networking is copied.
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/reading_stats.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';

/// 阅读热力图：16 周 × 7 天，周一在每列第一行。点一格在图下方显示那天的
/// 时长，默认显示今天；今天之后的格子不可点。
class ClassicMineHeatmap extends StatefulWidget {
  final ReadingStats stats;
  final DateTime today;

  const ClassicMineHeatmap({
    super.key,
    required this.stats,
    required this.today,
  });

  @override
  State<ClassicMineHeatmap> createState() => _ClassicMineHeatmapState();
}

class _ClassicMineHeatmapState extends State<ClassicMineHeatmap> {
  DateTime? _picked;

  static const _gap = 3.0;
  static const _weekdayLabels = ['周一', '', '周三', '', '周五', '', ''];

  @override
  void didUpdateWidget(ClassicMineHeatmap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final today = DateUtils.dateOnly(widget.today);
    final picked = _picked;
    if (picked == null ||
        DateUtils.isSameDay(today, DateUtils.dateOnly(oldWidget.today))) {
      return;
    }
    if (picked.isBefore(readingHeatmapDates(today).first) ||
        picked.isAfter(today)) {
      _picked = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final today = DateUtils.dateOnly(widget.today);
    final dates = readingHeatmapDates(today);
    final shown = _picked ?? today;
    final labelHeight = MediaQuery.textScalerOf(context).scale(10) * 1.2;
    final rowHeight = labelHeight > 14 ? labelHeight : 14.0;
    final labelStyle = TextStyle(
      fontSize: 10,
      height: 1.2,
      color: palette.muted,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HomeSectionHeader(title: '阅读热力图'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (final date in [dates.first, dates[56], dates.last])
                    Expanded(
                      child: Text(
                        '${date.month}月',
                        textAlign: TextAlign.center,
                        style: labelStyle.copyWith(fontSize: 11),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Semantics(
                container: true,
                label: '最近16周阅读热力图，可用前一天和后一天按钮查看每日阅读时长',
                child: ExcludeSemantics(
                  child: _grid(
                    palette,
                    dates,
                    today,
                    shown,
                    rowHeight,
                    labelStyle,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              _dayInspector(palette, dates, today, shown),
              if (!DateUtils.isSameDay(shown, today))
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('reading-heatmap-today'),
                    onPressed: () => setState(() => _picked = null),
                    icon: const Icon(LucideIcons.calendar_check, size: 16),
                    label: const Text('回到今天'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: palette.accentText,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dayInspector(
    HomePalette palette,
    List<DateTime> dates,
    DateTime today,
    DateTime shown,
  ) {
    final previous = DateTime(shown.year, shown.month, shown.day - 1);
    final next = DateTime(shown.year, shown.month, shown.day + 1);
    final canGoPrevious = !previous.isBefore(dates.first);
    final canGoNext = !next.isAfter(today);
    final minutes = widget.stats.minutesOn(shown);
    final duration = minutes > 0 ? formatReadingDuration(minutes) : '未阅读';
    final label =
        '${shown.year}年${shown.month}月${shown.day}日，'
        '${_dayLabel(shown, today)}，$duration';
    return Column(
      children: [
        Semantics(
          container: true,
          liveRegion: true,
          label: '阅读日期，$label',
          excludeSemantics: true,
          child: Text(
            '${shown.year}年${shown.month}月${shown.day}日'
            '${DateUtils.isSameDay(shown, today) ? ' · 今天' : ''}',
            key: const ValueKey('reading-heatmap-full-day'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.ink,
              fontSize: 12,
              height: 1.3,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Row(
          children: [
            IconButton(
              key: const ValueKey('reading-heatmap-previous-day'),
              tooltip: '前一天',
              onPressed: canGoPrevious
                  ? () => _selectDay(previous, today)
                  : null,
              icon: const Icon(LucideIcons.chevron_left, size: 20),
            ),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  '${_dayLabel(shown, today)} · $duration',
                  key: const ValueKey('reading-heatmap-day'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: palette.muted,
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('reading-heatmap-next-day'),
              tooltip: '后一天',
              onPressed: canGoNext ? () => _selectDay(next, today) : null,
              icon: const Icon(LucideIcons.chevron_right, size: 20),
            ),
          ],
        ),
      ],
    );
  }

  Widget _grid(
    HomePalette palette,
    List<DateTime> dates,
    DateTime today,
    DateTime shown,
    double rowHeight,
    TextStyle labelStyle,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            for (var row = 0; row < 7; row++) ...[
              if (row > 0) const SizedBox(height: _gap),
              SizedBox(
                height: rowHeight,
                child: Center(
                  child: Text(_weekdayLabels[row], style: labelStyle),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            children: [
              for (var row = 0; row < 7; row++) ...[
                if (row > 0) const SizedBox(height: _gap),
                SizedBox(
                  height: rowHeight,
                  child: Row(
                    children: [
                      for (var col = 0; col < 16; col++) ...[
                        if (col > 0) const SizedBox(width: _gap),
                        Flexible(
                          child: _cell(
                            palette,
                            dates,
                            col * 7 + row,
                            today,
                            shown,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _cell(
    HomePalette palette,
    List<DateTime> dates,
    int index,
    DateTime today,
    DateTime shown,
  ) {
    final date = dates[index];
    final future = date.isAfter(today);
    final level = future ? 0 : readingHeatLevel(widget.stats.minutesOn(date));
    // 墨水屏的 line 是纯黑，空格子若照用会比读过的格子还深：改成白底黑边，
    // 读过的格子用黑色深浅分级。
    final heat = palette.eink ? Colors.black : HomePalette.accent;
    final color = switch (level) {
      1 => heat.withValues(alpha: 0.18),
      2 => heat.withValues(alpha: 0.4),
      3 => heat.withValues(alpha: 0.65),
      4 => heat,
      _ => future || palette.eink ? Colors.transparent : palette.line,
    };
    final selected = !future && date == shown;
    final outline = palette.eink && level == 0 && !future;
    return GestureDetector(
      key: ValueKey('reading-heatmap-cell-$index'),
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: future ? null : () => _selectDay(date, today),
      child: SizedBox(
        width: 14,
        child: AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
              border: selected
                  ? Border.all(color: palette.ink, width: 1.2)
                  : outline
                  ? Border.all(color: Colors.black, width: 0.6)
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  void _selectDay(DateTime date, DateTime today) {
    final day = DateUtils.dateOnly(date);
    if (day.isAfter(today)) return;
    setState(() => _picked = day);
  }
}

String _dayLabel(DateTime day, DateTime today) {
  if (day == today) return '今天';
  if (day == DateTime(today.year, today.month, today.day - 1)) return '昨天';
  return '${day.month}月${day.day}日';
}
