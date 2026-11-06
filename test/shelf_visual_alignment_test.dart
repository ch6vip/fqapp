import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/shelf/shelf_empty.dart';
import 'package:fqapp/widgets/wenku/shelf_toolbar.dart';
import 'package:fqapp/widgets/wenku/wenku_icons.dart';
import 'package:fqapp/widgets/wenku/wenku_theme.dart';

/// 书架视觉对齐回归：archive 空态尺度、今日已读胶囊描边、收藏类型筛选选中态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-shelf-visual-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // 临时目录清理失败只是噪音。
    }
  });

  Widget host(Widget child) => MaterialApp(
    theme: WenkuTheme.create(Brightness.light),
    home: Scaffold(body: child),
  );

  testWidgets('三种空态与筛选空态统一 34dp 图标、17sp 标题、12sp 说明', (tester) async {
    final cases = <(Widget, String)>[
      (const ShelfEmptyState(), '书架暂无书籍'),
      (const ShelfCollectionEmptyState(text: '暂无收藏内容'), '暂无收藏内容'),
      (const ShelfEmptyHint(text: '未找到相关内容'), '未找到相关内容'),
      (const ShelfFilteredEmptyState(text: '没有符合筛选的书籍'), '没有符合筛选的书籍'),
    ];
    for (final (state, title) in cases) {
      await tester.pumpWidget(host(state));
      await tester.pumpAndSettle();
      final icon = tester.widget<ArchiveIcon>(find.byType(ArchiveIcon).first);
      expect(icon.size, 34);
      final text = tester.widget<Text>(find.text(title));
      expect(text.style?.fontSize, 17);
      expect(text.style?.fontWeight, FontWeight.w600);
    }
  });

  testWidgets('空书架保留去书城 / 离线缓存 Key，筛选空态保留清除筛选 Key', (tester) async {
    await tester.pumpWidget(
      host(ShelfEmptyState(onBrowse: () {}, onCachedBooks: () {})),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shelf-browse-button')), findsOneWidget);
    expect(find.byKey(const Key('shelf-cached-books-button')), findsOneWidget);
    final message = tester.widget<Text>(find.text('去书城发现海量故事，随时随地畅读'));
    expect(message.style?.fontSize, 12);

    await tester.pumpWidget(
      host(ShelfFilteredEmptyState(text: '没有符合筛选的书籍', onClearFilters: () {})),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shelf-clear-filters')), findsOneWidget);
  });

  testWidgets('今日已读胶囊常规无描边、墨水屏有黑描边', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: WenkuTheme.create(Brightness.light),
        home: const Scaffold(body: ShelfTodayReadingPill(minutes: 0)),
      ),
    );
    await tester.pumpAndSettle();
    var pill = tester.widget<Container>(
      find
          .ancestor(of: find.text('今日已读0分钟'), matching: find.byType(Container))
          .first,
    );
    expect((pill.decoration! as BoxDecoration).border, isNull);

    await tester.pumpWidget(
      MaterialApp(
        theme: WenkuTheme.create(Brightness.light, eink: true),
        home: const Scaffold(body: ShelfTodayReadingPill(minutes: 0)),
      ),
    );
    await tester.pumpAndSettle();
    pill = tester.widget<Container>(
      find
          .ancestor(of: find.text('今日已读0分钟'), matching: find.byType(Container))
          .first,
    );
    final border = (pill.decoration! as BoxDecoration).border;
    expect(border, isNotNull);
    expect((border! as Border).top.color, Colors.black);
  });

  testWidgets('收藏 tab 的类型筛选保留生产 Key 且选中态可区分', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();

    final all = find.byKey(const Key('library-collection-filter-all'));
    final video = find.byKey(const Key('library-collection-filter-video'));
    expect(all, findsOneWidget);
    expect(video, findsOneWidget);
    expect(
      tester.getSemantics(all).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(
      tester.getSemantics(video).flagsCollection.isSelected,
      Tristate.isFalse,
    );

    await tester.tap(video);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(all).flagsCollection.isSelected,
      Tristate.isFalse,
    );
    expect(
      tester.getSemantics(video).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    handle.dispose();
  });
}
