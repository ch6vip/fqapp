import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/pages/stats_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/widgets/lazy_indexed_stack.dart';

void main() {
  late Directory directory;
  final store = LibraryStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-visible-pages-');
    Hive.init(directory.path);
    await store.init();
  });

  tearDown(() async {
    debugOnRebuildDirtyWidget = null;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('hidden shelf and statistics catch up on the next tab visit', (
    tester,
  ) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: index,
          builder: (context, value, child) => LazyIndexedStack(
            index: value,
            children: const [
              LibraryPage(),
              Scaffold(body: StatsPage()),
              SizedBox.expand(child: Text('其他页面')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    index.value = 1;
    await tester.pumpAndSettle();
    index.value = 2;
    await tester.pumpAndSettle();
    final builds = _recordBuilds();
    for (var update = 0; update < 10; update++) {
      await _saveProgress(tester, update);
      await tester.pump(const Duration(milliseconds: 300));
    }
    debugOnRebuildDirtyWidget = null;
    debugPrint('rendering: hidden tabs $builds');
    expect(builds, isEmpty);

    // 书架 tab 的集合是本地的，这次写入只落在阅读历史上，所以在第二个
    // tab 上验证「下次可见时追上最新数据」。
    index.value = 0;
    await tester.pumpAndSettle();
    expect(find.text('书架暂无书籍'), findsOneWidget);
    await tester.tap(find.text('浏览历史'));
    await tester.pumpAndSettle();
    expect(find.text('最新记录 9'), findsWidgets);
    expect(find.text('10%'), findsOneWidget);
    index.value = 1;
    await tester.pumpAndSettle();
    expect(find.text('10分钟'), findsWidgets);
    await _showRecentBook(tester, '最新记录 9');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an opaque route defers a pending statistics refresh until pop', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: StatsPage()),
      ),
    );
    await tester.pumpAndSettle();
    await _saveProgress(tester, 0);
    unawaited(
      navigator.currentState!.push<void>(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              const Scaffold(body: Text('播放页面')),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final builds = _recordBuilds();
    await tester.pump(const Duration(milliseconds: 300));
    await _saveProgress(tester, 1);
    await tester.pump(const Duration(milliseconds: 300));
    debugOnRebuildDirtyWidget = null;
    expect(builds, isEmpty);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('2分钟'), findsWidgets);
    await _showRecentBook(tester, '最新记录 1');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _showRecentBook(WidgetTester tester, String title) async {
  await tester.scrollUntilVisible(
    find.text('最近阅读'),
    200,
    scrollable: find
        .descendant(
          of: find.byType(StatsPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  expect(find.text(title), findsWidgets);
}

Future<void> _saveProgress(WidgetTester tester, int update) async {
  await tester.runAsync(() async {
    await LibraryStore.instance.addHistory({
      'id': 'visible-book',
      'bookId': 'visible-book',
      'kind': 'video',
      'title': '最新记录 $update',
      'episode': update,
      'progress': (update + 1) / 100,
      'time': DateTime.now().millisecondsSinceEpoch,
    });
    await LibraryStore.instance.accumulateReadTime('visible-book', 'video', 60);
  });
}

Map<String, int> _recordBuilds() {
  final builds = <String, int>{};
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (element.widget is LibraryPage || element.widget is StatsPage) {
      final name = element.widget.runtimeType.toString();
      builds.update(name, (count) => count + 1, ifAbsent: () => 1);
    }
  };
  return builds;
}
