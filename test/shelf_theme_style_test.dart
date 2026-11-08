import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/classic_shelf_layout.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/shelf_view_store.dart';
import 'package:fqapp/widgets/bookshelf_card.dart';
import 'package:fqapp/widgets/search/search_media_tile.dart';
import 'package:fqapp/widgets/shelf/book_collection_tiles.dart';
import 'package:fqapp/widgets/shelf/shelf_collection_view.dart';
import 'package:fqapp/widgets/shelf/shelf_design.dart';
import 'package:fqapp/widgets/shelf/shelf_cover_image.dart';
import 'package:fqapp/widgets/wenku/book_collection_layout.dart';
import 'package:fqapp/widgets/wenku/wenku_archive.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final source in ['fanqie', 'shuqi']) {
    testWidgets('$source row drops only decorative code and its gap', (
      tester,
    ) async {
      final style = ValueNotifier<AppStyleTokens>(
        const AppStyleTokens.archive(),
      );
      addTearDown(style.dispose);
      final item = _item(source: source);
      final row = ShelfNovelRow(
        key: const Key('test-row'),
        item: item,
        badge: '更新',
        meta: '测试作者',
        progress: '第5章 · 共20章',
        cached: true,
        fanqieImported: true,
        onTap: () {},
      );
      await tester.pumpWidget(_host(style, SingleChildScrollView(child: row)));
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveCode), findsOneWidget);
      expect(
        find.text(source == 'shuqi' ? 'SQ-00123' : 'FQ-00123'),
        findsOneWidget,
      );
      final archiveHeight = tester.getSize(find.byKey(row.key!)).height;
      expect(
        tester.widget<ShelfCoverImage>(find.byType(ShelfCoverImage)).radius,
        3,
      );

      style.value = const AppStyleTokens.classic();
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveCode), findsNothing);
      expect(find.textContaining('FQ-'), findsNothing);
      expect(find.textContaining('SQ-'), findsNothing);
      expect(find.text(item.title), findsWidgets);
      expect(find.text('第5章 · 共20章'), findsOneWidget);
      expect(find.text('更新'), findsOneWidget);
      expect(find.textContaining('缓存'), findsOneWidget);
      expect(find.textContaining('番茄导入'), findsOneWidget);
      if (source == 'shuqi') {
        expect(find.textContaining('书旗'), findsOneWidget);
      }
      expect(
        tester.widget<ShelfCoverImage>(find.byType(ShelfCoverImage)).radius,
        10,
      );
      final details = tester.widget<Column>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Column &&
              widget.children.any(
                (child) => child is Text && child.data == '第5章 · 共20章',
              ),
        ),
      );
      expect(details.children.first, isA<Text>());
      expect((details.children.first as Text).data, item.title);
      expect(
        tester.getSize(find.byKey(row.key!)).height,
        lessThan(archiveHeight),
      );
      expect(tester.takeException(), isNull);

      style.value = const AppStyleTokens.archive();
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveCode), findsOneWidget);
      expect(tester.getSize(find.byKey(row.key!)).height, archiveHeight);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('search rows switch IDs and radius without a blank code lane', (
    tester,
  ) async {
    final style = ValueNotifier<AppStyleTokens>(const AppStyleTokens.archive());
    addTearDown(style.dispose);
    final item = _item(source: 'shuqi');
    final row = SearchNovelRow(item: item, onTap: () {});
    await tester.pumpWidget(_host(style, SingleChildScrollView(child: row)));
    await tester.pumpAndSettle();
    expect(find.text('SQ-00123'), findsOneWidget);
    final archiveHeight = tester.getSize(find.byType(SearchNovelRow)).height;

    style.value = const AppStyleTokens.classic();
    await tester.pumpAndSettle();
    expect(find.byType(ArchiveCode), findsNothing);
    expect(find.text(item.title), findsWidgets);
    expect(find.textContaining(searchMediaMeta(item)), findsOneWidget);
    expect(find.textContaining('书旗'), findsOneWidget);
    final clip = tester.widget<ClipRRect>(
      find
          .descendant(
            of: find.byType(SearchNovelRow),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(clip.borderRadius, BorderRadius.circular(10));
    final details = tester.widget<Column>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Column &&
                widget.children.any(
                  (child) => child is Text && child.data == item.title,
                ),
          )
          .last,
    );
    expect((details.children.first as Text).data, item.title);
    expect(
      tester.getSize(find.byType(SearchNovelRow)).height,
      lessThan(archiveHeight),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cached grid rows react to style without changing requested density',
    (tester) async {
      final style = ValueNotifier<AppStyleTokens>(
        const AppStyleTokens.archive(),
      );
      addTearDown(style.dispose);
      final item = _item(source: 'shuqi');
      const density = BookGridDensity.sized(BookGridSize.large);
      final collection = ShelfCollectionView(
        mode: BookCollectionMode.grid,
        density: density,
        itemCount: 1,
        regionToolbar: const SizedBox.shrink(),
        padding: EdgeInsets.zero,
        itemBuilder: (_, _) => ShelfBookGridTile(
          item: item,
          badge: '更新',
          progress: '第5章 · 共20章',
          meta: '测试作者',
          cached: true,
          fanqieImported: true,
          onTap: () {},
        ),
        emptyBuilder: (_) => const SizedBox.shrink(),
      );
      await tester.pumpWidget(_host(style, collection));
      await tester.pumpAndSettle();
      for (final tokens in [
        const AppStyleTokens.classic(),
        const AppStyleTokens.archive(),
      ]) {
        style.value = tokens;
        await tester.pumpAndSettle();
        expect(
          tester.widget<ShelfCoverImage>(find.byType(ShelfCoverImage)).radius,
          tokens.coverRadius,
        );
        expect(find.text(item.title), findsWidgets);
        expect(find.text('第5章 · 共20章'), findsOneWidget);
        expect(find.text('更新'), findsOneWidget);
        expect(find.textContaining('缓存'), findsOneWidget);
        expect(find.textContaining('番茄导入'), findsOneWidget);
        final view = tester.widget<BookCollectionView>(
          find.byType(BookCollectionView),
        );
        expect(view.grid, isTrue);
        expect(view.gridDensity, density);
        expect(tester.takeException(), isNull);
      }
    },
  );

  group('retained library page', () {
    late Directory directory;

    setUp(() async {
      setSingleChapterPrefs({'shelfLayout': 'list'});
      ShelfViewStore.instance.resetForTest();
      ClassicShelfLayout.instance.resetForTest();
      directory = await Directory.systemTemp.createTemp('fqapp-shelf-theme-');
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      await ShelfGroupStore.instance.init();
    });

    tearDown(() async {
      await ClassicShelfLayout.instance.whenIdle();
      await ShelfGroupStore.instance.whenIdle();
      await Hive.close();
      await directory.delete(recursive: true);
      ShelfViewStore.instance.resetForTest();
    });

    for (final mode in BookCollectionMode.values) {
      testWidgets('${mode.name} and selection survive theme switches', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        setSingleChapterPrefs({'shelfLayout': mode.storageValue});
        await tester.runAsync(() async {
          await ShelfViewStore.instance.load();
          await ShelfStore.instance.add(_item());
          await LibraryStore.instance.addHistory({
            'id': '123',
            'kind': 'book',
            'title': '测试书籍',
            'episode': 4,
            'chapterCount': 20,
            'progress': .5,
          });
        });
        final style = ValueNotifier<AppStyleTokens>(
          const AppStyleTokens.archive(),
        );
        addTearDown(style.dispose);
        final page = LibraryPage(cacheStore: MemoryChapterCache());
        await tester.pumpWidget(_host(style, page, width: 400, textScale: 1.4));
        await tester.pumpAndSettle();
        final state = tester.state(find.byType(LibraryPage));
        final tileKey = ValueKey(
          mode.isGrid ? 'shelf-grid-book-book:123' : 'shelf-book-book:123',
        );
        final tile = find.byKey(tileKey);
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        await tester.longPress(tile);
        await tester.pumpAndSettle();
        expect(find.text('已选择 1 本'), findsOneWidget);

        final archiveItem = mode.isGrid
            ? tester.widget<ShelfBookGridTile>(tile).item
            : tester.widget<ShelfNovelRow>(tile).item;
        style.value = const AppStyleTokens.classic();
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(LibraryPage)), same(state));
        expect(ShelfViewStore.instance.mode, mode);
        expect(ClassicShelfLayout.instance.value, BookshelfLayout.grid);
        expect(find.byType(ShelfCollectionView), findsNothing);
        expect(
          find.byKey(const ValueKey('archive-shelf-carousel')),
          findsNothing,
        );
        expect(find.text('已选择 1 本'), findsOneWidget);
        final classic = tester.widget<BookshelfGridCard>(
          find.byKey(const ValueKey('shelf-grid-book:123')),
        );
        expect(classic.item, same(archiveItem));
        expect(classic.editing, isTrue);
        expect(classic.selected, isTrue);
        expect(classic.infoText, '第5章 · 共20章');
        expect(tester.takeException(), isNull);

        style.value = const AppStyleTokens.archive();
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(LibraryPage)), same(state));
        expect(ShelfViewStore.instance.mode, mode);
        expect(
          (await SharedPreferences.getInstance()).getString(
            ShelfViewStore.layoutKey,
          ),
          mode.storageValue,
        );
        final collection = tester.widget<ShelfCollectionView>(
          find.byType(ShelfCollectionView),
        );
        expect(collection.mode, mode);
        expect(
          collection.padding.left,
          const AppStyleTokens.archive().pageGutter,
        );
        expect(
          find.byKey(const ValueKey('archive-shelf-carousel')),
          mode.hasShelf ? findsOneWidget : findsNothing,
        );
        expect(find.text('已选择 1 本'), findsOneWidget);
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        if (mode.isGrid) {
          final selected = tester.widget<ShelfBookGridTile>(tile);
          expect(selected.editing, isTrue);
          expect(selected.selected, isTrue);
          expect(selected.item, same(archiveItem));
        } else {
          final selected = tester.widget<ShelfNovelRow>(tile);
          expect(selected.editing, isTrue);
          expect(selected.selected, isTrue);
          expect(selected.item, same(archiveItem));
          expect(
            find.descendant(of: tile, matching: find.byType(ArchiveCode)),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(of: tile, matching: find.text('第5章 · 共20章')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  });
}

Widget _host(
  ValueNotifier<AppStyleTokens> style,
  Widget child, {
  double width = 320,
  double textScale = 2,
}) => ValueListenableBuilder<AppStyleTokens>(
  valueListenable: style,
  child: child,
  builder: (context, tokens, child) => MaterialApp(
    themeAnimationDuration: Duration.zero,
    theme: ThemeData(extensions: [tokens]),
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  ),
);

MediaItem _item({String source = 'fanqie'}) => MediaItem(
  id: '123',
  title: '测试书籍',
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '20',
  kind: 'book',
  source: source,
);
