import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/shelf_view_store.dart';

import 'support/fakes.dart';

/// 书架分组：三 tab 共用归属、作者分类、移出保留归属、删本地书清归属、
/// 分组未就绪只读。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    setSingleChapterPrefs({'shelfLayout': 'list'});
    ShelfViewStore.instance.resetForTest();
    directory = await Directory.systemTemp.createTemp('fqapp-shelf-groups-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
  });

  tearDown(() async {
    await ShelfGroupStore.instance.whenIdle();
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

  testWidgets('分组作用于书架 / 浏览历史 / 收藏三个 tab', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late String group;
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('shelf-book', title: '书架的书'));
      await ShelfStore.instance.add(
        _item('video-book', title: '收藏的短剧', kind: 'video'),
      );
      await LibraryStore.instance.addHistory({
        'id': 'history-book',
        'kind': 'book',
        'title': '历史的书',
        'time': DateTime.now().millisecondsSinceEpoch,
      });
      group = await ShelfGroupStore.instance.addGroup('想读');
      await ShelfGroupStore.instance.assignKeys([
        'book:shelf-book',
        'book:history-book',
        'video:video-book',
      ], group);
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _chooseCategory(tester, '想读');
    expect(_rowKeys(tester), ['shelf-book-book:shelf-book']);

    await tester.tap(find.text('浏览历史'));
    await tester.pumpAndSettle();
    await _chooseCategory(tester, '想读');
    expect(_rowKeys(tester), ['shelf-book-book:history-book']);

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    await _chooseCategory(tester, '想读');
    expect(_rowKeys(tester), ['shelf-book-video:video-book']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按作者自动分类', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('a', title: '甲书', author: '作者甲'));
      await ShelfStore.instance.add(_item('b', title: '乙书', author: '作者乙'));
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('shelf-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-by-author')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-author-作者甲')));
    await tester.pumpAndSettle();
    expect(_rowKeys(tester), ['shelf-book-book:a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('移出书架保留分组归属', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late String group;
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('a', title: '甲书'));
      group = await ShelfGroupStore.instance.addGroup('想读');
      await ShelfGroupStore.instance.assignKeys(['book:a'], group);
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('shelf-book-book:a')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('shelf-remove-action')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(ShelfStore.instance.records(), isEmpty);
    expect(ShelfGroupStore.instance.groupOfKey('book:a'), group);
  });

  testWidgets('删除本地导入书同时清理分组归属', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late String group;
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('local_1_ab', title: '本地书'));
      group = await ShelfGroupStore.instance.addGroup('想读');
      await ShelfGroupStore.instance.assignKeys(['book:local_1_ab'], group);
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey('shelf-book-book:local_1_ab')),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final removed = Completer<void>();
      void onChanged() {
        if (!removed.isCompleted) removed.complete();
      }

      final changes = ShelfGroupStore.instance.listenable;
      changes.addListener(onChanged);
      try {
        await tester.tap(find.byKey(const Key('shelf-remove-action')));
        // The assignment changes only after its Hive write and flush finish.
        await removed.future;
      } finally {
        changes.removeListener(onChanged);
      }
    });
    await tester.pumpAndSettle();
    expect(ShelfStore.instance.records(), isEmpty);
    expect(
      ShelfGroupStore.instance.groupOfKey('book:local_1_ab'),
      ShelfGroupStore.unfiled,
    );
  });

  testWidgets('分组未就绪时分类弹层只读且不写回', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('a', title: '甲书'));
      await EncryptedHive.box<dynamic>(Hive, ShelfGroupStore.boxName).close();
    });
    expect(ShelfGroupStore.instance.isReady, isFalse);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('shelf-category')));
    await tester.pumpAndSettle();
    expect(find.text('分类暂不可用，请稍后再试'), findsOneWidget);
    // 只读弹层只提供「全部书籍」，不产生分类写入。
    await tester.tap(find.text('全部书籍').last);
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getString('shelfCategory'),
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('分组未就绪时持久化的组分类降级为全部，不筛空页面', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 上次会话持久化的组分类还在，但这次分组仓库打不开。
    setSingleChapterPrefs({'shelfLayout': 'list', 'shelfCategory': 'gabc-12'});
    ShelfViewStore.instance.resetForTest();
    await tester.runAsync(() async {
      await ShelfStore.instance.add(_item('a', title: '甲书'));
      await EncryptedHive.box<dynamic>(Hive, ShelfGroupStore.boxName).close();
    });
    expect(ShelfGroupStore.instance.isReady, isFalse);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // 未就绪时 `groupOfKey` 恒为 `_unfiled`，持久化的组 id 永远匹配不到；
    // 页面必须安全降级为「全部书籍」，而不是整页为空（design D-M4）。
    expect(find.byKey(const ValueKey('shelf-book-book:a')), findsOneWidget);
    expect(find.text('全部书籍'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

List<String> _rowKeys(WidgetTester tester) {
  final keys = <String>{};
  for (final element in find.byType(Text).evaluate()) {
    element.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<String> && key.value.startsWith('shelf-book-')) {
        keys.add(key.value);
        return false;
      }
      return true;
    });
  }
  return keys.toList();
}

Future<void> _chooseCategory(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const Key('shelf-category')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

Widget _app() => const MaterialApp(home: LibraryPage());

MediaItem _item(
  String id, {
  String? title,
  String kind = 'book',
  String author = '测试作者',
}) => MediaItem(
  id: id,
  title: title ?? id,
  cover: '',
  author: author,
  badge: '',
  ep: '120',
  kind: kind,
);
