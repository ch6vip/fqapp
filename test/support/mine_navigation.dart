import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Wenku8 MyPage moved fqapp's statistics behind the 「统计」 entry.
/// Tests that check those statistics open the entry first; their assertions
/// on the heatmap, ranking and refresh behaviour stay unchanged.
Future<void> openMineStatistics(WidgetTester tester) async {
  final entry = find.byKey(const ValueKey('mine-statistics'));
  await tester.scrollUntilVisible(
    entry,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

/// The statistics list, for scrolling within that page.
Finder get statisticsScrollable => find
    .descendant(
      of: find.byKey(const ValueKey('reading-statistics-list')),
      matching: find.byType(Scrollable),
    )
    .first;
