import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/mine_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/library_store.dart';

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
      expect(find.text('今日阅读'), findsOneWidget);
      expect(find.text('阅读热力图'), findsOneWidget);
      for (final weekday in {0: '周一', 2: '周三', 4: '周五'}.entries) {
        final label = find.text(weekday.value);
        final cell = find.byKey(
          ValueKey('reading-heatmap-cell-${weekday.key}'),
        );
        expect(label, findsOneWidget);
        expect(cell, findsOneWidget);
        expect(
          tester.getCenter(label).dy,
          closeTo(tester.getCenter(cell).dy, 0.01),
          reason: '${weekday.value} must align with its calendar row',
        );
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

  testWidgets('the title-bar gear opens app settings', (tester) async {
    final observer = _RouteObserver();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(navigatorObservers: [observer], home: const MinePage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('应用设置'));
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
    expect(find.text('小说章节'), findsOneWidget);
    expect(find.text('短剧剧集'), findsOneWidget);
  });

  testWidgets('tapping a heatmap day shows its minutes', (tester) async {
    await readFor(tester, 'today-book', 'book');
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: MinePage()));
    await tester.pumpAndSettle();
    final readout = find.byKey(const ValueKey('reading-heatmap-day'));
    expect(tester.widget<Text>(readout).data, '今天 · 1分钟');
    // Column 0 is fifteen weeks back, so its Monday is never today.
    await tester.tap(find.byKey(const ValueKey('reading-heatmap-cell-0')));
    await tester.pump();
    expect(tester.widget<Text>(readout).data, endsWith(' · 未阅读'));
    expect(find.text('今天 · 1分钟'), findsNothing);
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
    final showAll = find.text('全部');
    await tester.scrollUntilVisible(showAll, 200);
    expect(find.text('听书 book6'), findsNothing, reason: 'preview stops at 5');
    await tester.tap(showAll);
    await tester.pumpAndSettle();
    expect(find.text('全部 7 本'), findsOneWidget);
    final sheet = find.byType(BottomSheet);
    final last = find.descendant(of: sheet, matching: find.text('听书 book6'));
    await tester.scrollUntilVisible(
      last,
      200,
      scrollable: find
          .descendant(of: sheet, matching: find.byType(Scrollable))
          .first,
    );
    final context = tester.element(find.byType(MinePage));
    await tester.tap(last);
    await tester.pump();
    final page =
        (observer.lastRoute! as MaterialPageRoute).builder(context)
            as DetailPage;
    expect(page.item.id, 'book6');
    expect(page.item.kind, 'audio');
  });
}

/// Taps a 读得最多 row and returns the detail page it pushed.
Future<DetailPage> _openRankedTitle(WidgetTester tester, String title) async {
  final observer = _RouteObserver();
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(navigatorObservers: [observer], home: const MinePage()),
  );
  await tester.pumpAndSettle();
  final row = find.text(title);
  await tester.scrollUntilVisible(row, 200);
  final context = tester.element(find.byType(MinePage));
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
