import 'package:flutter/material.dart';

import '../../models/reading_stats.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';

/// 首屏摘要：今日时长作大字，本周 / 累计 / 连续天数作一行副信息。
class MineSummary extends StatelessWidget {
  final ReadingStats stats;
  final DateTime today;

  const MineSummary({super.key, required this.stats, required this.today});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final todayMinutes = stats.minutesOn(today);
    final week = stats.weekMinutes(today);
    final streak = stats.streakDays(today);
    final detail = stats.isEmpty
        ? '读书、听书、看剧的时长都会记在这里'
        : [
            '本周 ${formatReadingDuration(week)}',
            '累计 ${formatReadingDuration(stats.totalMinutes)}',
            if (streak > 0) '连续 $streak 天',
          ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(homeGutter, 8, homeGutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '今日阅读',
            style: TextStyle(fontSize: 13, height: 1.3, color: palette.muted),
          ),
          const SizedBox(height: 4),
          Text(
            todayMinutes > 0 ? formatReadingDuration(todayMinutes) : '还没开始',
            key: const ValueKey('mine-today-minutes'),
            style: TextStyle(
              fontSize: 30,
              height: 1.2,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: palette.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: TextStyle(fontSize: 13, height: 1.4, color: palette.muted),
          ),
        ],
      ),
    );
  }
}
