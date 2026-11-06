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
//   ranked books and the 16-week heatmap window. 「当前文库」 uses the real
//   local shelf (`MineLibraryOverview`); bookmark and touch dimensions have
//   no local store and are not synthesised here.
// - `_statisticsArrival` and `_ChangingValue` are kept: metric values still
//   fade/slide in with the shared archive clock and exchange softly on change;
//   they collapse to a static child when motion is disabled.
// - The insight line is window-scoped: `ratio` and `activeAverage` both use
//   the 16-week heatmap window, matching upstream's range-scoped metrics.
//   fqapp's map distinguishes "recorded zero" (a key with 0 minutes) from
//   "no record" (no key), so only a wholly empty stats map renders
//   「尚未开始记录」; a 16-week window with no reading still shows 0%.
// - `_Metric('本周阅读')` restores the pre-port summary's 本周 figure, which
//   upstream has no single equivalent for outside its range picker.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/reading_stats.dart';
import '../wenku/reading_charts.dart';
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
    // Both insight figures use the same 16-week window as the calendar.
    final windowMinutes = window.fold<double>(
      0,
      (sum, day) => sum + stats.minutesOn(day),
    );
    final ratio = stats.isEmpty ? null : windowActive / window.length;
    final activeAverage = windowActive == 0
        ? 0.0
        : windowMinutes / windowActive;
    final peak = _peakDay(stats);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '阅读总览', code: 'READING / AT A GLANCE'),
        const SizedBox(height: 20),
        _statisticsArrival(
          context,
          start: .08,
          end: .62,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
            ],
          ),
        ),
        const SizedBox(height: 24),
        _Metrics([
          _Metric(
            '活跃天数',
            '$activeDays',
            '天',
            key: const ValueKey('mine-metric-active-days'),
          ),
          if (stats.rank.isNotEmpty)
            _Metric(
              '读过的书',
              '${stats.rank.length}',
              '本',
              key: const ValueKey('mine-metric-books'),
            ),
          _Metric(
            '连续阅读',
            '${stats.streakDays(today)}',
            '天',
            key: const ValueKey('mine-metric-streak'),
          ),
          _Metric(
            '今日阅读',
            '${stats.minutesOn(today).round()}',
            '分钟',
            key: const ValueKey('mine-metric-today'),
          ),
          _Metric(
            '本周阅读',
            '${stats.weekMinutes(today).round()}',
            '分钟',
            key: const ValueKey('mine-metric-week'),
          ),
        ]),
        const SizedBox(height: 24),
        _statisticsArrival(
          context,
          start: .18,
          end: .78,
          child: Container(
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
                    ReadingActivityRing(ratio: ratio, size: 56),
                  ],
                ),
                const SizedBox(height: 7),
                AppText(
                  ratio == null
                      ? '尚未开始记录'
                      : '近 16 周活跃占比 ${(ratio * 100).round()}%  ·  '
                            '活跃日平均 ${formatReadingDuration(activeAverage)}',
                  style: muted.copyWith(height: 1.7),
                ),
              ],
            ),
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

/// Upstream `_statisticsArrival`: rides the shared archive clock instead of
/// starting a private ticker. Static when motion is disabled.
Widget _statisticsArrival(
  BuildContext context, {
  required Widget child,
  required double start,
  required double end,
}) {
  final scope = ArchiveMotionScope.maybeOf(context);
  if (scope == null ||
      !scope.enabled ||
      MediaQuery.disableAnimationsOf(context)) {
    return child;
  }
  final progress = scope.animation.drive(
    CurveTween(curve: Interval(start, end, curve: Curves.easeOutCubic)),
  );
  return FadeTransition(
    opacity: progress,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, .12),
        end: Offset.zero,
      ).animate(progress),
      child: RepaintBoundary(child: child),
    ),
  );
}

/// Actual values exchange softly; no counting through invented measurements.
class _ChangingValue extends StatelessWidget {
  const _ChangingValue({required this.value, required this.child});

  final Object value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        ArchiveMotionScope.maybeOf(context)?.enabled == false;
    if (reduced) return child;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [
          for (final child in previous) ExcludeSemantics(child: child),
          ?current,
        ],
      ),
      transitionBuilder: (child, progress) => FadeTransition(
        opacity: progress,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, .13),
            end: Offset.zero,
          ).animate(progress),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(value), child: child),
    );
  }
}

/// Upstream overview's 「当前文库 · 日期」 block after the range metrics:
/// fqapp has a local shelf and reading history, so 藏书 and 有阅读记录 are
/// real measurements. Bookmark/light-note counts have no local store and are
/// not invented.
class MineLibraryOverview extends StatelessWidget {
  const MineLibraryOverview({
    super.key,
    required this.today,
    required this.shelfBooks,
    required this.readingBooks,
  });

  final DateTime today;
  final int shelfBooks;
  final int readingBooks;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          '当前文库 · ${today.year}.${today.month}.${today.day}',
          style: muted,
        ),
        const SizedBox(height: 16),
        _Metrics([
          _Metric(
            '藏书',
            '$shelfBooks',
            '本',
            key: const ValueKey('mine-metric-shelf'),
          ),
          _Metric(
            '有阅读记录',
            '$readingBooks',
            '本',
            key: const ValueKey('mine-metric-reading'),
          ),
        ]),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.unit, {super.key});

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
            _ChangingValue(
              value: value,
              child: AppText(
                value,
                style: const TextStyle(
                  fontSize: 29,
                  height: 1.1,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -1,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
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
