import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';

/// 备份页的分组文案：预览计数、恢复完成文案、帮助文案与分组不可用提示。
///
/// 页面本身由另一个工作流改外观；这里只钉住分组相关的逻辑与文案。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final library = LibraryStore.instance;
  final shelf = ShelfStore.instance;
  final groups = ShelfGroupStore.instance;
  const channel = MethodChannel('fqapp/library_backup');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-backup-page-');
    Hive.init(directory.path);
    await library.init();
    await shelf.init();
    await groups.init();
  });

  tearDown(() async {
    await groups.whenIdle();
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temp directory cleanup is noise.
    }
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const LibraryBackupPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  void mockChannel(WidgetTester tester, {Uint8List? open, bool saved = true}) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'openBackup':
          return open;
        case 'saveBackup':
          return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  /// Taps a row whose handler performs real Hive/isolate work, then pumps until
  /// [expected] appears. Widget tests run in a fake-async zone, so the real
  /// work has to happen inside `runAsync`.
  Future<void> tapAndWait(
    WidgetTester tester,
    Finder target,
    Finder expected,
  ) async {
    await tester.runAsync(() async {
      await tester.tap(target);
    });
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (expected.evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets('preview shows the group and assignment counts', (tester) async {
    mockChannel(tester, open: _groupedBackupBytes());
    await pumpPage(tester);

    await tapAndWait(tester, find.text('从备份文件恢复'), find.text('分组'));

    expect(find.text('分组'), findsOneWidget);
    expect(find.text('归属'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('只补充缺失的收藏、进度与分组'), findsOneWidget);
  });

  testWidgets('restore completion message includes group counts', (
    tester,
  ) async {
    mockChannel(tester, open: _groupedBackupBytes());
    await pumpPage(tester);

    await tapAndWait(tester, find.text('从备份文件恢复'), find.text('分组'));
    await tapAndWait(tester, find.text('确认恢复到本机'), find.textContaining('个分组（'));

    expect(find.textContaining('2 个分组（3 条分类归属）'), findsOneWidget);
  });

  testWidgets('help copy mentions shelf groups', (tester) async {
    mockChannel(tester);
    await pumpPage(tester);

    // The help card sits below the fold; the list builds lazily.
    await tester.scrollUntilVisible(
      find.text('备份包含哪些内容？'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份包含哪些内容？'));
    await tester.pumpAndSettle();

    expect(find.textContaining('书架分组'), findsOneWidget);
  });

  testWidgets('export warns when the group store is unavailable', (
    tester,
  ) async {
    mockChannel(tester);
    await tester.runAsync(
      () => EncryptedHive.box<dynamic>(Hive, ShelfGroupStore.boxName).close(),
    );
    expect(groups.isReady, isFalse);
    await pumpPage(tester);

    await tapAndWait(
      tester,
      find.text('导出备份'),
      find.textContaining('本次备份不含书架分组'),
    );

    expect(find.textContaining('本次备份不含书架分组'), findsOneWidget);
  });
}

/// 2 个分组、3 条归属、1 条收藏、1 条进度。
Uint8List _groupedBackupBytes() {
  final backup = LibraryBackup.capture(
    shelf: [
      ShelfRecord(
        item: MediaItem(
          id: '1',
          title: '作品',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
        addedAt: DateTime(2020),
      ),
    ],
    history: [
      {'id': '1', 'kind': 'book'},
    ],
    watched: {},
    groups: {
      'version': 1,
      'groups': {
        'g1-a': {'name': '想读', 'at': 1, 'deleted': false},
        'g2-b': {'name': '在读', 'at': 2, 'deleted': false},
      },
      'assignments': {
        'book:1': {'group': 'g1-a', 'at': 1},
        'book:2': {'group': 'g1-a', 'at': 2},
        'book:3': {'group': 'g2-b', 'at': 3},
      },
    },
  );
  return backup.encode();
}
