import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/reading_stats.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/mine_page.dart';
import 'package:fqapp/pages/reading_statistics_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/widgets/home/home_sheet.dart';
import 'package:fqapp/widgets/mine/mine_heatmap.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/mine_navigation.dart';

void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-mine-page-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> readFor(
    WidgetTester tester,
    String id,
    String kind, {
    double seconds = 60,
  }) => tester.runAsync(
    () => LibraryStore.instance.accumulateReadTime(id, kind, seconds),
  );

  for (final scale in [1.0, 1.8]) {
    testWidgets('我的 fits a narrow phone at text scale $scale', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
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
          home: const MinePage(),
        ),
      );
      await tester.pumpAndSettle();
      await openMineStatistics(tester);
      expect(find.text('阅读总览'), findsOneWidget);
      await _scrollToCalendar(tester);
      expect(find.text('阅读日历'), findsOneWidget);
      // 16 weeks split at 14 weeks per segment: two segments in this layout.
      const segments = 2;
      for (final weekday in {0: '一', 2: '三', 4: '五'}.entries) {
        final labels = find.text(weekday.value);
        expect(labels, findsNWidgets(segments));
        for (var segment = 0; segment < segments; segment++) {
          final cell = find.byKey(
            ValueKey('reading-heatmap-cell-${segment * 14 * 7 + weekday.key}'),
          );
          expect(cell, findsOneWidget);
          expect(
            tester.getCenter(labels.at(segment)).dx,
            closeTo(tester.getCenter(cell).dx, 0.01),
            reason: '${weekday.value} 标签要与第 $segment 段对应列的水平中心对齐',
          );
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the profile card and colored shortcut tiles are gone', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: MinePage()));
    await tester.pumpAndSettle();
    expect(find.text('书友'), findsNothing);
    expect(find.text('沉浸阅读，记录每一个好故事'), findsNothing);
    expect(find.text('每日记录'), findsNothing);
    expect(find.text('最近封面'), findsNothing);
    await tester.scrollUntilVisible(find.text('关于'), 200);
    for (final label in ['离线缓存', '备份与导入', '关于']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('the 设置 entry opens app settings', (tester) async {
    final observer = _RouteObserver();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(navigatorObservers: [observer], home: const MinePage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    final context = tester.element(find.byType(MinePage));
    final route = observer.lastRoute! as MaterialPageRoute;
    expect(route.builder(context), isA<SettingsPage>());
  });

  testWidgets('offline cache offers the novel and drama caches', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: MinePage()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('离线缓存'), 200);
    await tester.tap(find.text('离线缓存'));
    await tester.pumpAndSettle();
    expect(find.text('小说离线缓存'), findsOneWidget);
    expect(find.text('短剧离线缓存'), findsOneWidget);
  });

  testWidgets('mine list leaves room for the floating navigation bar', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: MinePage()));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(MinePage));
    final list = tester.widget<ListView>(find.byType(ListView).first);
    expect(
      (list.padding! as EdgeInsets).bottom,
      DockLayout.scrollPaddingOf(context),
      reason: '底部留白跟随悬浮导航栏高度与系统手势条，而不是写死 88',
    );
  });

  testWidgets('tapping a heatmap day shows its minutes', (tester) async {
    await readFor(tester, 'today-book', 'book');
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: MinePage()));
    await tester.pumpAndSettle();
    await openMineStatistics(tester);
    await _scrollToCalendar(tester);
    final readout = find.byKey(const ValueKey('reading-heatmap-day'));
    expect(tester.widget<Text>(readout).data, '今天 · 1分钟');
    // Column 0 is fifteen weeks back, so its Monday is never today.
    await tester.tap(find.byKey(const ValueKey('reading-heatmap-cell-0')));
    await tester.pump();
    expect(tester.widget<Text>(readout).data, endsWith(' · 未阅读'));
    expect(find.text('今天 · 1分钟'), findsNothing);
  });

  testWidgets('e-ink empty days stay lighter than days with reading', (
    tester,
  ) async {
    final original = einkModeNotifier.value;
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = original);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: MinePage()));
    await tester.pumpAndSettle();
    await openMineStatistics(tester);
    await _scrollToCalendar(tester);
    final empty = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const ValueKey('reading-heatmap-cell-0')),
        matching: find.byType(DecoratedBox),
      ),
    );
    final decoration = empty.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);
    expect(decoration.border, isNotNull, reason: 'empty days are outlined');
  });

  testWidgets('recorded zero minutes use the first fill, not the outline', (
    tester,
  ) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final stats = ReadingStats.from(
      history: const [],
      readTime: {
        'zero-book': {readingDayKey(today): 0.0},
      },
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MineHeatmap(stats: stats, today: today),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final index = readingHeatmapDates(
      today,
    ).indexWhere((day) => DateUtils.isSameDay(day, today));
    final todayCell = find.byKey(ValueKey('reading-heatmap-cell-$index'));
    final zero = tester.widget<DecoratedBox>(
      find.descendant(of: todayCell, matching: find.byType(DecoratedBox)),
    );
    final zeroDecoration = zero.decoration as BoxDecoration;
    expect(
      zeroDecoration.border,
      isNull,
      reason: 'recorded days are not outlined',
    );
    expect(zeroDecoration.color, isNot(Colors.transparent));

    final neverRead = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const ValueKey('reading-heatmap-cell-0')),
        matching: find.byType(DecoratedBox),
      ),
    );
    final neverDecoration = neverRead.decoration as BoxDecoration;
    expect(neverDecoration.color, Colors.transparent);
    expect(neverDecoration.border, isNotNull);
  });

  for (final media in const {'audio': '听书', 'manga': '漫画'}.entries) {
    testWidgets('retained ${media.key} time reopens the original content ID', (
      tester,
    ) async {
      await readFor(tester, '${media.key}:shared', media.key);
      final page = await _openRankedTitle(tester, '${media.value} shared');
      expect(page.item.id, 'shared');
      expect(page.item.kind, media.key);
    });
  }

  testWidgets('read-time-only entries reopen with the recorded kind', (
    tester,
  ) async {
    await readFor(tester, 'orphan-video', 'video');
    final page = await _openRankedTitle(tester, 'orphan-video');
    expect(page.item.id, 'orphan-video');
    expect(page.item.kind, 'video');
  });

  testWidgets('全部 lists every ranked book and opens the tapped one', (
    tester,
  ) async {
    // Distinct durations keep the order deterministic: book6 ranks last.
    for (var i = 0; i < 7; i++) {
      await readFor(tester, 'audio:book$i', 'audio', seconds: (7 - i) * 60.0);
    }
    final observer = _RouteObserver();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(navigatorObservers: [observer], home: const MinePage()),
    );
    await tester.pumpAndSettle();
    await openMineStatistics(tester);
    final showAll = find.text('全部');
    await tester.scrollUntilVisible(
      showAll,
      200,
      scrollable: statisticsScrollable,
    );
    expect(find.text('听书 book6'), findsNothing, reason: 'preview stops at 5');
    await tester.ensureVisible(showAll);
    await tester.pumpAndSettle();
    await tester.tap(showAll);
    await tester.pumpAndSettle();
    expect(find.text('全部 7 本'), findsOneWidget);
    expect(find.byType(HomeSheetFrame), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    final sheet = find.byType(BottomSheet);
    final last = find.descendant(of: sheet, matching: find.text('听书 book6'));
    await tester.scrollUntilVisible(
      last,
      200,
      scrollable: find
          .descendant(of: sheet, matching: find.byType(Scrollable))
          .first,
    );
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(ReadingStatisticsPage));
    await tester.tap(last);
    await tester.pump();
    final page =
        (observer.lastRoute! as MaterialPageRoute).builder(context)
            as DetailPage;
    expect(page.item.id, 'book6');
    expect(page.item.kind, 'audio');
  });
}

/// The archive statistics page keeps 阅读日历 below 阅读总览 and 阅读节律, so a
/// phone viewport only builds it after scrolling the statistics list.
Future<void> _scrollToCalendar(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('reading-heatmap-cell-0')),
    220,
    scrollable: statisticsScrollable,
  );
}

/// Taps a 读得最多 row and returns the detail page it pushed.
Future<DetailPage> _openRankedTitle(WidgetTester tester, String title) async {
  final observer = _RouteObserver();
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(navigatorObservers: [observer], home: const MinePage()),
  );
  await tester.pumpAndSettle();
  await openMineStatistics(tester);
  final row = find.text(title);
  await tester.scrollUntilVisible(row, 200, scrollable: statisticsScrollable);
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(ReadingStatisticsPage));
  await tester.tap(row);
  await tester.pump();
  return (observer.lastRoute! as MaterialPageRoute).builder(context)
      as DetailPage;
}

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? lastRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      lastRoute = route;
}
