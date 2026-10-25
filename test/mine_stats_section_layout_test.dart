import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/mine_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/widgets/stats/stats_overview_grid.dart';

/// Issue #141: on 我的 the 阅读与视听统计 heading sat outside the card while
/// every other section drew its heading (red bar + text) inside one, and the
/// overview card ended with dead space above the heatmap.
void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-mine-review-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('统计 heading is drawn once, inside the summary card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(const MaterialApp(home: MinePage()));
    await tester.pumpAndSettle();

    final heading = find.text('阅读与视听统计');
    expect(heading, findsOneWidget);

    // The heading must share a card with the overview tiles: both are inside
    // the same _Card, which is the nearest decorated surface above each.
    expect(find.byType(StatsOverviewGrid), findsOneWidget);
    final headingCard = _nearestCard(tester.element(heading));
    final overviewCard = _nearestCard(
      tester.element(find.byType(StatsOverviewGrid)),
    );
    expect(headingCard, isNotNull, reason: '统计 heading must sit in a card');
    expect(
      identical(headingCard, overviewCard),
      isTrue,
      reason: '统计 heading and the overview tiles belong to one card',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('overview tiles leave no dead space at the bottom', (
    tester,
  ) async {
    for (final scale in [1.0, 1.8]) {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          // ListView 给的是纵向无界约束，网格因此按自身内容取高 —— 这正是
          // StatsPage 里卡片内的真实情形。
          home: Scaffold(
            body: ListView(
              children: const [
                StatsOverviewGrid(
                  stats: [
                    ('--', '今日'),
                    ('--', '本月'),
                    ('0分钟', '总计'),
                    ('0 天', '活跃天数'),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final grid = find.byType(StatsOverviewGrid);
      final tiles = find.descendant(of: grid, matching: find.byType(Container));
      expect(tiles, findsNWidgets(4));

      // The last tile's bottom must coincide with the grid's bottom: a fixed
      // grid extent that does not match the content shows up exactly here.
      final gridRect = tester.getRect(grid);
      final lastTile = tester.getRect(tiles.last);
      expect(
        lastTile.bottom,
        closeTo(gridRect.bottom, 0.5),
        reason: 'no dead space under the last tile at text scale $scale',
      );
      expect(tester.takeException(), isNull);
    }
  });
}

/// The nearest ancestor element that paints a card: a Container with a
/// border-radius decoration. The overview tiles also use Containers, so the
/// search walks up until it leaves the heading's own text styles behind.
Element? _nearestCard(Element element) {
  Element? found;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Container) {
      final decoration = widget.decoration;
      if (decoration is BoxDecoration && decoration.borderRadius != null) {
        found = ancestor;
        return false;
      }
    }
    return true;
  });
  return found;
}
