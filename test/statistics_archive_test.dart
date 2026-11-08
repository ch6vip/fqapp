import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reading_statistics_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/settings/settings_archive_page.dart';

/// Regression coverage for the statistics route moved onto the Wenku8 archive
/// shell: the archive sections render and the rhythm chart keeps its day
/// selection behaviour.
void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-statistics-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('统计页以档案分区呈现，节律图可选日期', (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: ReadingStatisticsPage()));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsArchivePage), findsOneWidget);
    expect(find.text('阅读总览'), findsOneWidget);

    final list = find.byKey(const ValueKey('reading-statistics-list'));
    await tester.scrollUntilVisible(
      find.text('阅读节律'),
      200,
      scrollable: find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('阅读节律'), findsOneWidget);
    final chart = find.byKey(const ValueKey('misc-reading-rhythm-gesture'));
    await tester.ensureVisible(chart);
    await tester.pumpAndSettle();
    expect(chart, findsOneWidget);

    final today = DateTime.now();
    final todayLabel = '${today.year}年${today.month}月${today.day}日';
    expect(find.text(todayLabel), findsOneWidget);

    // Tapping the middle of the trace moves the selected day away from today.
    await tester.tap(chart);
    await tester.pump();
    expect(find.text(todayLabel), findsNothing);
  });

  testWidgets('当前文库展示本机藏书与有阅读记录', (tester) async {
    await tester.runAsync(
      () => ShelfStore.instance.add(
        MediaItem(
          id: 'shelf-book',
          title: '书架里的书',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
      ),
    );
    await tester.runAsync(
      () => LibraryStore.instance.accumulateReadTime('read-book', 'book', 120),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: ReadingStatisticsPage()));
    await tester.pumpAndSettle();

    final overview = find.textContaining('当前文库 · ');
    await tester.scrollUntilVisible(
      overview,
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('reading-statistics-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(overview, findsOneWidget);
    expect(_metricValue(tester, 'mine-metric-shelf'), '1');
    expect(_metricValue(tester, 'mine-metric-reading'), '1');
  });
}

/// The numeric value inside one statistics metric, found by its stable key.
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
