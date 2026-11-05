// Upstream source: Wenku8_Flutter rev ebcd7f1
//   lib/reading_statistics_page.dart (_overview, _insight, _Number, _Metric,
//     _Metrics, _muted)
// Mechanical substitutions:
// - `AppText`/`ArchiveSection`/`ArchivePart` come from the vendored
//   `lib/widgets/wenku/` shared layer; `appText` is not needed because fqapp
//   ships one Chinese locale.
// - `ReadingStatisticsData` fields (periodSeconds, activeDays, averageSeconds,
//   peakDate, activeRatio) are replaced by the aggregates fqapp's
//   `ReadingStats` actually records: all-time minutes, active days, streak,
//   ranked books and the 16-week heatmap window. No upstream-only dimension
//   (bookmarks, collection, touch) is synthesised here.
// - `_Metric('今日阅读')` keeps fqapp's today figure; upstream has no
//   equivalent because its overview is range-scoped.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/reading_stats.dart';
import '../wenku/misc_reading_charts.dart';
import '../wenku/wenku_ui.dart';

/// 首屏摘要：本机累计时长作大字，活跃天数 / 读过的书 / 连续天数作一行
/// 副信息，末尾保留上游的洞察条（最投入的一天 + 活跃占比环）。
class MineSummary extends StatelessWidget {
  final ReadingStats stats;
  final DateTime today;

  const MineSummary({super.key, required this.stats, required this.today});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: scheme.onSurfaceVariant,
    );
    final activeDays = stats.dayMinutes.values.where((v) => v > 0).length;
    final window = readingHeatmapDates(DateUtils.dateOnly(today));
    final windowActive = window.where((day) => stats.minutesOn(day) > 0).length;
    final ratio = window.isEmpty ? null : windowActive / window.length;
    final activeAverage = activeDays == 0
        ? 0.0
        : stats.totalMinutes / activeDays;
    final peak = _peakDay(stats);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '阅读总览', code: 'READING / AT A GLANCE'),
        const SizedBox(height: 20),
        AppText('本机累计 · 阅读时长', style: muted),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: AppText(
            formatReadingDuration(stats.totalMinutes),
            key: const ValueKey('mine-total-minutes'),
            style: const TextStyle(
              fontSize: 38,
              height: 1.1,
              fontWeight: FontWeight.w500,
              letterSpacing: -1,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 24),
        _Metrics([
          _Metric('活跃天数', '$activeDays', '天'),
          if (stats.rank.isNotEmpty)
            _Metric('读过的书', '${stats.rank.length}', '本'),
          _Metric('连续阅读', '${stats.streakDays(today)}', '天'),
          _Metric('今日阅读', '${stats.minutesOn(today).round()}', '分钟'),
        ]),
        const SizedBox(height: 24),
        Container(
          key: const ValueKey('statistics-period-insight'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: .055),
            border: Border(left: BorderSide(color: scheme.primary, width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppText(
                      peak == null
                          ? '让下一次翻页成为起点'
                          : '${peak.month}月${peak.day}日，是这段时间最投入的一天',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.6,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  MiscReadingActivityRing(
                    ratio: ratio == null || ratio <= 0 ? null : ratio,
                    size: 56,
                  ),
                ],
              ),
              const SizedBox(height: 7),
              AppText(
                ratio == null || ratio <= 0
                    ? '尚未开始记录'
                    : '近 16 周活跃占比 ${(ratio * 100).round()}%  ·  '
                          '活跃日平均 ${formatReadingDuration(activeAverage)}',
                style: muted.copyWith(height: 1.7),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 近 16 周里阅读时长最多的一天；没有记录时返回 null。
  DateTime? _peakDay(ReadingStats stats) {
    DateTime? best;
    var bestMinutes = 0.0;
    for (final day in readingHeatmapDates(DateUtils.dateOnly(today))) {
      final minutes = stats.minutesOn(day);
      if (minutes > bestMinutes) {
        bestMinutes = minutes;
        best = day;
      }
    }
    return best;
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.unit);

  final String label, value, unit;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label $value $unit',
    excludeSemantics: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          label,
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 5,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            AppText(
              value,
              style: const TextStyle(
                fontSize: 29,
                height: 1.1,
                fontWeight: FontWeight.w500,
                letterSpacing: -1,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: AppText(
                unit,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _Metrics extends StatelessWidget {
  const _Metrics(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const count = 2;
      final width = (constraints.maxWidth - 14 * (count - 1)) / count;
      return Wrap(
        spacing: 14,
        runSpacing: 20,
        children: [
          for (var index = 0; index < children.length; index++)
            SizedBox(width: math.max(0, width), child: children[index]),
        ],
      );
    },
  );
}
