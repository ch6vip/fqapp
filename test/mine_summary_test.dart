import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/reading_stats.dart';
import 'package:fqapp/widgets/mine/mine_summary.dart';

/// The overview's insight line is window-scoped and never confuses "no record
/// at all" with "nothing read in the last 16 weeks".
void main() {
  final today = DateUtils.dateOnly(DateTime(2026, 11, 6));

  Future<void> pump(WidgetTester tester, ReadingStats stats) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MineSummary(stats: stats, today: today),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('无任何记录时显示尚未开始记录', (tester) async {
    await pump(tester, ReadingStats.empty);
    expect(find.text('尚未开始记录'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(_metricValue(tester, 'mine-metric-week'), '0');
  });

  testWidgets('记录全部在 16 周窗口外时显示 0% 而不是尚未开始', (tester) async {
    final stats = ReadingStats.from(
      history: const [],
      readTime: {
        'old-book': {'2020-1-1': 60.0},
      },
    );
    await pump(tester, stats);
    expect(find.text('尚未开始记录'), findsNothing);
    expect(find.textContaining('近 16 周活跃占比 0%'), findsOneWidget);
    expect(find.textContaining('活跃日平均 0分钟'), findsOneWidget);
    expect(find.text('让下一次翻页成为起点'), findsOneWidget);
  });

  testWidgets('洞察与本周指标使用同一份窗口数据', (tester) async {
    final stats = ReadingStats.from(
      history: const [],
      readTime: {
        'today-book': {readingDayKey(today): 1800.0},
      },
    );
    await pump(tester, stats);
    expect(find.textContaining('近 16 周活跃占比 1%'), findsOneWidget);
    expect(find.textContaining('活跃日平均 30分钟'), findsOneWidget);
    expect(_metricValue(tester, 'mine-metric-week'), '30');
    expect(_metricValue(tester, 'mine-metric-today'), '30');
  });
}

String? _metricValue(WidgetTester tester, String key) {
  final metric = find.byKey(ValueKey(key));
  final texts = tester.widgetList<Text>(
    find.descendant(
      of: metric,
      matching: find.byWidgetPredicate((widget) => widget is Text),
    ),
  );
  return texts
      .map((text) => text.data)
      .firstWhere((data) => data != null && RegExp(r'^\d+$').hasMatch(data));
}
