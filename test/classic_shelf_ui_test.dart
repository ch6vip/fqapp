import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/shelf_categories.dart';
import 'package:fqapp/models/shelf_view_state.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/book_open_preferences.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/classic_shelf_layout.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/shelf_view_store.dart';
import 'package:fqapp/widgets/bookshelf_card.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/shelf/shelf_collection_view.dart';
import 'package:fqapp/widgets/shelf/shelf_design.dart';
import 'package:fqapp/widgets/wenku/archive_shelf.dart';
import 'package:fqapp/widgets/wenku/book_collection_layout.dart';
import 'package:fqapp/widgets/wenku/shelf_toolbar.dart';
import 'package:fqapp/widgets/wenku/wenku_archive.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('classic layout persistence', () {
    tearDown(() => SharedPreferences.resetStatic());

    test('legacy 0/1/2 only, no migration or archive writes', () async {
      for (final legacy in <Object?>[null, 0, 1, 2, -1, 3, 6, '1', true]) {
        setSingleChapterPrefs({
          'shelfLayout': 'shelfGrid',
          'shelfGridDensity': '3x4',
          'bookshelf_layout': ?legacy,
        });
        final store = ClassicShelfLayout();
        await store.load();
        expect(
          store.value,
          legacy is int && legacy >= 0 && legacy <= 2
              ? BookshelfLayout.values[legacy]
              : BookshelfLayout.grid,
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.get('classic_bookshelf_layout'), isNull);
        expect(prefs.get('bookshelf_layout'), legacy);
        expect(prefs.get('shelfLayout'), 'shelfGrid');
        expect(prefs.get('shelfGridDensity'), '3x4');
        store.dispose();
      }
    });

    test('classic key wins; invalid classic value uses valid legacy', () async {
      for (final (saved, expected) in <(Object, BookshelfLayout)>[
        (0, BookshelfLayout.grid),
        (1, BookshelfLayout.doubleColumn),
        (2, BookshelfLayout.list),
        ('bad', BookshelfLayout.list),
        (9, BookshelfLayout.list),
      ]) {
        setSingleChapterPrefs({
          'classic_bookshelf_layout': saved,
          'bookshelf_layout': 2,
        });
        final store = ClassicShelfLayout();
        await store.load();
        expect(store.value, expected);
        expect(
          (await SharedPreferences.getInstance()).get(
            'classic_bookshelf_layout',
          ),
          saved,
        );
        store.dispose();
      }
    });

    test(
      'a tap during a delayed load wins, including tapping default grid',
      () async {
        for (final choice in [
          BookshelfLayout.grid,
          BookshelfLayout.doubleColumn,
        ]) {
          setSingleChapterPrefs({'classic_bookshelf_layout': 2});
          final prefs = await SharedPreferences.getInstance();
          final read = Completer<SharedPreferences>();
          final entered = Completer<void>();
          var calls = 0;
          final store = ClassicShelfLayout(
            preferences: () {
              if (calls++ == 0) {
                entered.complete();
                return read.future;
              }
              return Future.value(prefs);
            },
          );
          final loading = store.load();
          await entered.future;
          final writing = store.setLayout(choice);
          expect(store.value, choice);
          read.complete(prefs);
          await Future.wait([loading, writing]);
          expect(store.value, choice);
          expect(prefs.getInt('classic_bookshelf_layout'), choice.index);
          store.dispose();
        }
      },
    );

    test(
      'writes serialize and a failed write cannot poison later taps',
      () async {
        SharedPreferences.resetStatic();
        final platform = _SlowFirstWrite();
        SharedPreferencesStorePlatform.instance = platform;
        final store = ClassicShelfLayout();
        final first = store.setLayout(BookshelfLayout.doubleColumn);
        final failed = expectLater(first, throwsStateError);
        await platform.started.future;
        final last = store.setLayout(BookshelfLayout.list);
        expect(store.value, BookshelfLayout.list);
        expect(platform.values, [1]);
        platform.release.complete();
        await failed;
        await last;
        await store.whenIdle();
        expect(platform.values, [1, 2]);
        expect(
          (await SharedPreferences.getInstance()).getInt(
            'classic_bookshelf_layout',
          ),
          2,
        );
        store.dispose();
        SharedPreferences.setMockInitialValues({});
      },
    );
  });

  group('classic shelf UI', () {
    late Directory directory;

    setUp(() async {
      setSingleChapterPrefs({
        'shelfLayout': 'shelfGrid',
        'shelfGridDensity': '3x4',
      });
      ShelfViewStore.instance.resetForTest();
      ClassicShelfLayout.instance.resetForTest();
      BookOpenPreferences.instance.resetForTest();
      directory = await Directory.systemTemp.createTemp('fqapp-classic-shelf-');
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      await ShelfGroupStore.instance.init();
    });

    tearDown(() async {
      await ClassicShelfLayout.instance.whenIdle();
      await ShelfViewStore.instance.whenIdle();
      await ShelfGroupStore.instance.whenIdle();
      await Hive.close();
      await directory.delete(recursive: true);
      ClassicShelfLayout.instance.resetForTest();
      ShelfViewStore.instance.resetForTest();
    });

    testWidgets(
      'old header, three-column cards, progress and no archive chrome',
      (tester) async {
        await _size(tester);
        await tester.runAsync(() async {
          await ShelfStore.instance.add(_item());
          await LibraryStore.instance.addHistory({
            'id': '123',
            'title': '测试书籍',
            'kind': 'book',
            'episode': 4,
            'chapterCount': 20,
            'progress': .5,
          });
        });
        final style = _style();
        await tester.pumpWidget(_app(style));
        await tester.pumpAndSettle();
        expect(find.text('书架'), findsOneWidget);
        expect(find.text('浏览历史'), findsOneWidget);
        expect(find.text('收藏'), findsOneWidget);
        expect(find.byKey(const Key('library-search-button')), findsOneWidget);
        expect(find.byKey(const Key('library-more-button')), findsOneWidget);
        expect(find.text('今日已读0分钟'), findsOneWidget);
        for (final name in ['grid', 'double', 'list']) {
          expect(find.byKey(Key('shelf-layout-$name')), findsOneWidget);
        }
        final underline = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('classic-tab-underline-书架')),
        );
        expect(underline.constraints!.maxWidth, 26);
        expect(
          (underline.decoration! as BoxDecoration).color,
          HomePalette.accent,
        );
        final grid = tester.widget<GridView>(find.byType(GridView));
        expect(
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          3,
        );
        final card = tester.widget<BookshelfGridCard>(
          find.byType(BookshelfGridCard),
        );
        expect(card.badgeText, '5/20');
        expect(card.infoText, '第5章 · 共20章');
        expect(find.text('5/20'), findsOneWidget);
        expect(find.text('第5章 · 共20章'), findsOneWidget);
        expect(find.byType(ArchiveMasthead), findsNothing);
        expect(find.byType(ArchiveFileCarousel), findsNothing);
        expect(find.byType(ShelfToolbar), findsNothing);
        expect(find.byType(ShelfCollectionView), findsNothing);
        expect(ShelfViewStore.instance.mode, BookCollectionMode.shelfGrid);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'double/list persist independently through theme switches and remount',
      (tester) async {
        await _size(tester);
        await tester.runAsync(() => ShelfStore.instance.add(_item()));
        final style = _style();
        await tester.pumpWidget(_app(style));
        await tester.pumpAndSettle();
        final state = tester.state(find.byType(LibraryPage));
        final density = ShelfViewStore.instance.state.density;
        for (final (segment, layout) in [
          ('double', BookshelfLayout.doubleColumn),
          ('list', BookshelfLayout.list),
        ]) {
          await tester.tap(find.byKey(Key('shelf-layout-$segment')));
          await tester.pumpAndSettle();
          await tester.runAsync(() => ClassicShelfLayout.instance.whenIdle());
          expect(
            find.byType(
              layout == BookshelfLayout.list
                  ? BookshelfListCard
                  : BookshelfDoubleCard,
            ),
            findsOneWidget,
          );
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getInt('classic_bookshelf_layout'), layout.index);
          expect(prefs.getString('shelfLayout'), 'shelfGrid');
          expect(prefs.getString('shelfGridDensity'), '3x4');
          style.value = const AppStyleTokens.archive();
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(LibraryPage)), same(state));
          expect(find.byType(ArchiveFileCarousel), findsOneWidget);
          expect(ShelfViewStore.instance.state.density, density);
          expect(ShelfViewStore.instance.mode, BookCollectionMode.shelfGrid);
          style.value = const AppStyleTokens.classic();
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(LibraryPage)), same(state));
          expect(ClassicShelfLayout.instance.value, layout);
          expect(find.byType(ArchiveFileCarousel), findsNothing);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        ClassicShelfLayout.instance.resetForTest();
        await tester.pumpWidget(_app(style));
        await tester.pumpAndSettle();
        expect(find.byType(BookshelfListCard), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'source-qualified selection and item identity survive a classic roundtrip',
      (tester) async {
        await _size(tester);
        final other = MediaItem(
          id: '123',
          title: '书旗同号书',
          cover: '',
          author: '另一作者',
          badge: '',
          ep: '',
          kind: 'book',
          source: 'shuqi',
        );
        await tester.runAsync(() async {
          await ShelfStore.instance.add(_item());
          await ShelfStore.instance.add(other);
        });
        final style = _style();
        await tester.pumpWidget(_app(style));
        await tester.pumpAndSettle();
        final state = tester.state(find.byType(LibraryPage));
        final first = find.byKey(const ValueKey('shelf-grid-book:123'));
        final second = find.byKey(const ValueKey('shelf-grid-shuqi/book:123'));
        final original = tester.widget<BookshelfGridCard>(first).item;
        final otherOriginal = tester.widget<BookshelfGridCard>(second).item;
        await tester.longPress(first);
        await tester.pumpAndSettle();
        expect(find.text('已选择 1 本'), findsOneWidget);
        expect(tester.widget<BookshelfGridCard>(second).selected, isFalse);
        expect(
          find.byKey(const Key('shelf-move-category-action')),
          findsOneWidget,
        );
        style.value = const AppStyleTokens.archive();
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(LibraryPage)), same(state));
        expect(find.text('已选择 1 本'), findsOneWidget);
        style.value = const AppStyleTokens.classic();
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(LibraryPage)), same(state));
        final restored = tester.widget<BookshelfGridCard>(first);
        final otherRestored = tester.widget<BookshelfGridCard>(second);
        expect(restored.item, same(original));
        expect(otherRestored.item, same(otherOriginal));
        expect(restored.editing, isTrue);
        expect(restored.selected, isTrue);
        expect(otherRestored.selected, isFalse);
        await tester.tap(first);
        await tester.pumpAndSettle();
        expect(find.text('已选择 0 本'), findsOneWidget);
        expect(find.byType(ReaderPage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('active archive filters remain visible and can be cleared', (
      tester,
    ) async {
      await _size(tester);
      late String group;
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item());
        group = await ShelfGroupStore.instance.addGroup('想读');
      });
      setSingleChapterPrefs({
        'shelfLayout': 'shelfGrid',
        'shelfSourceFilter': 'local',
        'shelfCategory': group,
      });
      await ShelfViewStore.instance.load();
      final style = _style();
      await tester.pumpWidget(_app(style));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('classic-shelf-active-filters')),
        findsOneWidget,
      );
      expect(find.text('已筛选 · 想读'), findsOneWidget);
      final clear = tester
          .widget<TextButton>(
            find.byKey(const Key('classic-shelf-clear-filters')),
          )
          .onPressed!;
      // ShelfViewStore's queue is initialized outside fake async. Invoke the
      // actual control callback in the same real-I/O zone and await its chain.
      await tester.runAsync(clear as Future<void> Function());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('classic-shelf-active-filters')),
        findsNothing,
      );
      expect(find.byType(BookshelfGridCard), findsOneWidget);
      expect(ShelfViewStore.instance.state.source, ShelfSourceFilter.all);
      expect(
        ShelfViewStore.instance.categoryOf(ShelfTabScope.shelf),
        ShelfCategory.all,
      );
      await tester.tap(find.byKey(const Key('library-more-button')));
      await tester.pumpAndSettle();
      for (final name in [
        'importBook',
        'cachedBooks',
        'filter',
        'categories',
        'edit',
      ]) {
        expect(find.byKey(Key('library-menu-$name')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final layout in BookshelfLayout.values) {
      testWidgets(
        '${layout.name}: one tap uses existing cached-resume route once',
        (tester) async {
          await _size(tester);
          setSingleChapterPrefs({
            'classic_bookshelf_layout': layout.index,
            'reader_page_mode': 'scroll',
          });
          final saved = <String, dynamic>{
            'id': '123',
            'kind': 'book',
            'title': '测试书籍',
            'chapterId': 'two',
            'episode': 0,
            'chapterCount': 2,
          };
          await tester.runAsync(() async {
            await ShelfStore.instance.add(_item());
            await LibraryStore.instance.addHistory(saved);
          });
          final cache = MemoryChapterCache();
          await cache.saveBook(
            CachedBook(
              id: '123',
              title: '测试书籍',
              chapters: [
                Chapter(itemId: 'one', title: '第一章', volumeName: ''),
                Chapter(itemId: 'two', title: '第二章', volumeName: ''),
              ],
            ),
          );
          for (final id in ['one', 'two']) {
            await cache.write(
              bookId: '123',
              chapterId: id,
              title: id,
              text: List.filled(30, '离线缓存正文。').join('\n\n'),
            );
          }
          var probes = 0;
          final observer = _PushObserver();
          final style = _style();
          await tester.pumpWidget(
            _app(
              style,
              observer: observer,
              page: LibraryPage(
                cacheStore: cache,
                readerStore: MemoryReaderStore(entry: saved),
                connectivity: () async {
                  probes++;
                  return (online: false, metered: false);
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          observer.pushes = 0;
          await tester.tap(
            find.byKey(ValueKey('shelf-${layout.segmentKey}-book:123')),
          );
          await tester.pumpAndSettle();
          expect(observer.pushes, 1);
          final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
          expect(reader.startIndex, 1);
          expect(reader.bookId, '123');
          expect(find.byType(DetailPage, skipOffstage: false), findsNothing);
          expect(probes, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  });
}

ValueNotifier<AppStyleTokens> _style() {
  final style = ValueNotifier<AppStyleTokens>(const AppStyleTokens.classic());
  addTearDown(style.dispose);
  return style;
}

Future<void> _size(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
}

Widget _app(
  ValueNotifier<AppStyleTokens> style, {
  LibraryPage? page,
  NavigatorObserver? observer,
}) => ValueListenableBuilder<AppStyleTokens>(
  valueListenable: style,
  child: page ?? LibraryPage(cacheStore: MemoryChapterCache()),
  builder: (context, tokens, child) => MaterialApp(
    themeAnimationDuration: Duration.zero,
    theme: ThemeData(extensions: [tokens]),
    navigatorObservers: [?observer],
    home: MediaQuery(
      data: const MediaQueryData(size: Size(400, 900), disableAnimations: true),
      child: child!,
    ),
  ),
);

MediaItem _item() => MediaItem(
  id: '123',
  title: '测试书籍',
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '20',
  kind: 'book',
);

class _PushObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

class _SlowFirstWrite extends InMemorySharedPreferencesStore {
  _SlowFirstWrite() : super.withData({});
  final started = Completer<void>();
  final release = Completer<void>();
  final values = <Object>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    values.add(value);
    if (values.length == 1) {
      started.complete();
      await release.future;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
