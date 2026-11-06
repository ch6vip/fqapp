import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/shelf_categories.dart';
import 'package:fqapp/models/shelf_identity.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/widgets/shelf/shelf_groups_sheet.dart';
import 'package:fqapp/widgets/wenku/wenku_theme.dart';

MediaItem _item(String id, {String author = '作者'}) => MediaItem(
  id: id,
  title: '书$id',
  cover: '',
  author: author,
  badge: '',
  ep: '',
  kind: 'book',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final store = ShelfGroupStore.instance;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('fqapp-groups-sheet-');
    Hive.init(directory.path);
    // The sheet tests exercise UI + in-memory state; real Hive file I/O would
    // never complete inside the widget-test fake-async zone.
    store.writeOrganization = (box, encoded) async {};
  });

  setUp(() async {
    store.maxVisibleGroups = 100;
    store.maxGroupRecords = ShelfGroupStore.hardMaxGroupRecords;
    store.maxAssignments = ShelfGroupStore.hardMaxAssignments;
    // Close every box, then reopen the underlying one in the real zone. The
    // store's own box handle stays closed, so its init() runs inside the fake
    // zone and its write queue belongs to that zone (a queue created in the
    // real zone never completes under FakeAsync).
    await Hive.close();
    await EncryptedHive.openBox<dynamic>(Hive, ShelfGroupStore.boxName);
  });

  tearDownAll(() async {
    try {
      await Hive.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () => const <void>[],
      );
    } catch (_) {
      // The read-only test closes Hive itself.
    }
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temp directory cleanup is noise.
    }
  });

  Future<void> pumpHost(
    WidgetTester tester, {
    required ValueNotifier<String?> result,
    List<MediaItem> items = const [],
    String selected = ShelfCategory.all,
    bool choose = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: WenkuTheme.create(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open-groups'),
                onPressed: () async {
                  result.value = choose
                      ? await chooseShelfCategory(
                          context,
                          store: store,
                          selected: selected,
                          reduceMotion: true,
                        )
                      : await showShelfGroupsSheet(
                          context,
                          store: store,
                          selected: selected,
                          reduceMotion: true,
                          items: items,
                        );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('open-groups')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('新建分类后返回新组 id', (tester) async {
    await store.init();
    final result = ValueNotifier<String?>(null);
    await pumpHost(tester, result: result);
    await openSheet(tester);
    expect(find.text('书籍分类'), findsOneWidget);

    await tester.tap(find.text('新建分类'));
    await settleSheet(tester);
    final field = find.byType(CupertinoTextField);
    expect(field, findsOneWidget);
    await tester.enterText(field, '想读');
    expect(tester.widget<CupertinoTextField>(field).controller!.text, '想读');
    await tester.ensureVisible(find.text('保存分类'));
    await tester.tap(find.text('保存分类'));
    await settleSheet(tester);

    expect(result.value, isNotNull);
    final id = store.groups.keys.single;
    expect(store.groups[id], '想读');
    expect(result.value, id);
  });

  testWidgets('重命名分类后返回原组 id', (tester) async {
    await store.init();
    final id = await store.addGroup('想读');
    final result = ValueNotifier<String?>(null);
    await pumpHost(tester, result: result, selected: id);
    await openSheet(tester);

    await tester.tap(find.byTooltip('重命名 想读'));
    await settleSheet(tester);
    await tester.enterText(find.byType(CupertinoTextField), '待读');
    await tester.ensureVisible(find.text('保存分类'));
    await tester.tap(find.text('保存分类'));
    await settleSheet(tester);

    expect(store.groups[id], '待读');
    expect(result.value, id);
  });

  testWidgets('删除当前分类后回落到全部书籍', (tester) async {
    await store.init();
    final id = await store.addGroup('想读');
    final result = ValueNotifier<String?>(null);
    await pumpHost(tester, result: result, selected: id);
    await openSheet(tester);

    await tester.tap(find.byTooltip('删除分类 想读'));
    await settleSheet(tester);
    expect(find.text('删除这个分类？'), findsOneWidget);
    await tester.tap(find.text('删除分类'));
    await settleSheet(tester);

    expect(store.groups, isEmpty);
    expect(result.value, ShelfCategory.all);
  });

  testWidgets('分配面板返回所选分类', (tester) async {
    await store.init();
    final id = await store.addGroup('想读');
    final result = ValueNotifier<String?>(null);
    await pumpHost(
      tester,
      result: result,
      selected: ShelfCategory.unfiled,
      choose: true,
    );
    await openSheet(tester);
    expect(find.text('移至分类'), findsOneWidget);

    await tester.tap(find.text('想读'));
    await settleSheet(tester);
    expect(result.value, id);
  });

  testWidgets('同名分类被拒绝并提示', (tester) async {
    await store.init();
    await store.addGroup('想读');
    final result = ValueNotifier<String?>(null);
    await pumpHost(tester, result: result);
    await openSheet(tester);

    await tester.tap(find.text('新建分类'));
    await settleSheet(tester);
    await tester.enterText(find.byType(CupertinoTextField), '想读');
    await tester.ensureVisible(find.text('保存分类'));
    await tester.tap(find.text('保存分类'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('已有同名分类'), findsOneWidget);
    expect(result.value, isNull);
    expect(find.text('保存分类'), findsOneWidget);
    // The notice lives in the root Overlay, not a page-level SnackBar that the
    // pushed sheet would cover.
    expect(find.byType(SnackBar), findsNothing);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('shelf-feedback')),
        matching: find.byType(Overlay),
      ),
      findsOneWidget,
    );
    // Let the transient notice's timer fire before the test zone ends.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('分类名输入限制 30 字', (tester) async {
    await store.init();
    final result = ValueNotifier<String?>(null);
    await pumpHost(tester, result: result);
    await openSheet(tester);
    await tester.tap(find.text('新建分类'));
    await settleSheet(tester);
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .maxLength,
      30,
    );
  });

  testWidgets('达到可见组上限后提示合并', (tester) async {
    await store.init();
    store.maxVisibleGroups = 1;
    await store.addGroup('想读');
    final result = ValueNotifier<String?>(null);
    await pumpHost(tester, result: result);
    await openSheet(tester);

    await tester.tap(find.text('新建分类'));
    await settleSheet(tester);
    await tester.enterText(find.byType(CupertinoTextField), '在读');
    await tester.ensureVisible(find.text('保存分类'));
    await tester.tap(find.text('保存分类'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('分类记录已满，请合并现有分类'), findsOneWidget);
    expect(result.value, isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('墓碑后分类从列表消失但归属保留', (tester) async {
    await store.init();
    final id = await store.addGroup('想读');
    final item = _item('1');
    await store.assignMany([item], id);
    await store.removeGroup(id);

    final result = ValueNotifier<String?>(null);
    await pumpHost(tester, result: result);
    await openSheet(tester);

    expect(find.text('想读'), findsNothing);
    expect(store.groupOf(item), ShelfCategory.unfiled);
    final assignments =
        store.exportOrganization()['assignments'] as Map<String, dynamic>;
    expect(assignments.containsKey(shelfContentKeyOf(item)), isTrue);
  });

  testWidgets('按作者分类返回作者分类键', (tester) async {
    await store.init();
    final result = ValueNotifier<String?>(null);
    await pumpHost(
      tester,
      result: result,
      items: [
        _item('1', author: '张三'),
        _item('2', author: '张三'),
        _item('3', author: '李四'),
      ],
    );
    await openSheet(tester);

    await tester.tap(find.text('按作者分类'));
    await settleSheet(tester);
    expect(find.text('张三'), findsOneWidget);
    expect(find.text('2 本'), findsOneWidget);

    await tester.tap(find.text('张三'));
    await settleSheet(tester);
    expect(result.value, shelfAuthorCategory('张三'));
  });

  testWidgets('分组未就绪时显示只读提示', (tester) async {
    await store.init();
    await tester.runAsync(() => Hive.close());
    expect(store.isReady, isFalse);

    final result = ValueNotifier<String?>(null);
    await pumpHost(tester, result: result);
    await openSheet(tester);
    expect(find.text('分类暂不可用，请稍后再试'), findsOneWidget);
  });

  testWidgets('分组未就绪时分配面板直接返回 null，不会返回 _all', (tester) async {
    await store.init();
    await tester.runAsync(() => Hive.close());
    expect(store.isReady, isFalse);

    final result = ValueNotifier<String?>('unchanged');
    await pumpHost(tester, result: result, choose: true);
    await openSheet(tester);
    expect(find.text('移至分类'), findsNothing);
    // `_all` is not a valid assignment target; the caller must keep its
    // current category instead.
    expect(result.value, isNull);
  });
}
