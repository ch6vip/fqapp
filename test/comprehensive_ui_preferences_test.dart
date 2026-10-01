import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/pages/stats_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/app_theme.dart';

void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-ui-preferences-');
    Hive.init(directory.path);
    final history = await Hive.openBox<dynamic>('history');
    await history.put('preserved-book', {
      'id': 'preserved-book',
      'kind': 'book',
      'title': '保留的阅读记录',
      'episode': 0,
      'progress': 0.25,
      'time': DateTime.now().millisecondsSinceEpoch,
    });
    await LibraryStore.instance.init();
    // 书架 tab 的数据来自本地收藏库，这里放一条与历史不同的作品。
    await ShelfStore.instance.init();
    await ShelfStore.instance.add(_shelfItem);
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('U02 invalid shelf layout retains history and default layout', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'bookshelf_layout': 'compact'});
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 无效偏好落到默认宫格，本地收藏仍在。
    expect(find.byKey(const Key('shelf-grid-view')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shelf-grid-book:shelf-book')),
      findsOneWidget,
    );
    expect(find.text('书架保留的书'), findsWidgets);
    await tester.tap(find.text('浏览历史'));
    await tester.pumpAndSettle();
    expect(find.text('保留的阅读记录'), findsWidgets);
    expect(
      LibraryStore.instance.historySnapshot().single['id'],
      'preserved-book',
    );
    await tester.tap(find.byKey(const Key('library-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-menu-switchList')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shelf-list-view')), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getInt('bookshelf_layout'),
      2,
    );
  });

  testWidgets('D02 failed history clear is reported without success feedback', (
    tester,
  ) async {
    _failPreferenceWrites(failClear: true);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.tap(find.text('数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    for (var frame = 0; frame < 4; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('清空失败，请重试'), findsOneWidget);
    expect(find.text('已清空'), findsNothing);
    expect(
      LibraryStore.instance.historySnapshot().single['id'],
      'preserved-book',
    );
  });

  testWidgets('U02 rejected layout write retains the selected usable layout', (
    tester,
  ) async {
    _failPreferenceWrites();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-menu-switchList')));
    await tester.pumpAndSettle();
    // 写失败也不能回退版式，网格里的数据要照常显示。
    expect(find.byKey(const Key('shelf-list-view')), findsOneWidget);
    expect(find.text('书架保留的书'), findsWidgets);
    expect(find.text('布局已更新，但未能保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('U02 rejected theme write applies the choice with feedback', (
    tester,
  ) async {
    _failPreferenceWrites();
    final originalMode = themeModeNotifier.value;
    themeModeNotifier.value = ThemeMode.system;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      themeModeNotifier.value = originalMode;
    });
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.dark);
    expect(find.text('外观已更新，但未能保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final statistics in [true, false]) {
    testWidgets('U02 optional preference read failure retains '
        '${statistics ? 'statistics' : 'shelf'}', (tester) async {
      _failPreferenceWrites(failLoad: true);
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(
          home: statistics
              ? const Scaffold(body: StatsPage())
              : const LibraryPage(),
        ),
      );
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      if (statistics) {
        expect(find.text('阅读热力图'), findsOneWidget);
      } else {
        // 偏好读失败时保留默认宫格；阅读历史仍能从第二个 tab 打开。
        expect(find.byKey(const Key('shelf-grid-view')), findsOneWidget);
        expect(find.text('书架保留的书'), findsWidgets);
        await tester.tap(find.text('浏览历史'));
        await tester.pumpAndSettle();
        expect(find.text('保留的阅读记录'), findsWidgets);
      }
      expect(LibraryStore.instance.historySnapshot(), hasLength(1));
    });
  }
}

void _failPreferenceWrites({
  bool throws = false,
  bool failLoad = false,
  bool failClear = false,
}) {
  final original = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  SharedPreferencesStorePlatform.instance = _FailingWriteStore(
    throws: throws,
    failLoad: failLoad,
    failClear: failClear,
  );
  addTearDown(() {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = original;
  });
}

class _FailingWriteStore extends InMemorySharedPreferencesStore {
  _FailingWriteStore({
    required this.throws,
    required this.failLoad,
    required this.failClear,
  }) : super.withData({});

  final bool throws;
  final bool failLoad;
  final bool failClear;

  @override
  Future<bool> remove(String key) async =>
      failClear ? false : super.remove(key);

  @override
  Future<Map<String, Object>> getAll() async {
    if (failLoad) throw PlatformException(code: 'cannot-read-preferences');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (throws) throw PlatformException(code: 'cannot-save-preference');
    return false;
  }
}

/// 书架页宫格里的保留作品。
final _shelfItem = MediaItem(
  id: 'shelf-book',
  title: '书架保留的书',
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '120',
  kind: 'book',
);
