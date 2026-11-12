import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
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
import 'package:fqapp/widgets/tab_swipe_area.dart';
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

    for (final initial in [0, 2]) {
      for (final swipe in [false, true]) {
        testWidgets('书架${swipe ? '滑动' : '点按'} $initial 到 1 下划线逐帧不越位', (
          tester,
        ) async {
          await _size(tester);
          await tester.pumpWidget(_app(_style(), disableAnimations: false));
          await tester.pumpAndSettle();
          if (initial == 2) {
            await tester.tap(find.text('收藏'));
            await tester.pumpAndSettle();
          }
          final indicator = find.byKey(const Key('classic-tab-underline'));
          final target = tester.getCenter(find.text('浏览历史')).dx;
          final direction = initial == 0 ? 1 : -1;
          var previous = tester.getCenter(indicator).dx;
          if (swipe) {
            // 真分页的吸附阈值是半页（起手还会吃掉一个 touch slop）。
            final gesture = await tester.startGesture(const Offset(200, 500));
            for (var frame = 0; frame < 24; frame++) {
              await gesture.moveBy(Offset(-10.0 * direction, 0));
              await tester.pump(const Duration(milliseconds: 16));
            }
            previous = tester.getCenter(indicator).dx;
            await gesture.up();
          } else {
            await tester.tap(find.text('浏览历史'));
          }
          await tester.pump();
          for (var frame = 0; frame < 45; frame++) {
            final centre = tester.getCenter(indicator).dx;
            expect(
              (centre - target) * direction,
              lessThanOrEqualTo(0.1),
              reason: '第 $frame 帧越过目标',
            );
            expect(
              (centre - previous) * direction,
              greaterThanOrEqualTo(-0.1),
              reason: '第 $frame 帧反向回弹',
            );
            previous = centre;
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(
            tester.widget<TabSwipeArea>(find.byType(TabSwipeArea)).index,
            1,
          );
          // 真分页落位允许亚像素残差（弹簧收尾），仍必须停在目标标签上。
          expect(previous, closeTo(target, .6));
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('依赖连续变化不会无限测量，下划线仍压在选中标签上', (tester) async {
      await _size(tester);
      await tester.pumpWidget(_app(_style(), disableAnimations: true));
      await tester.pumpAndSettle();

      // 连续改视口 = 连续 didChangeDependencies。若「测量 → setState →
      // 再测量」没有收敛，pumpAndSettle 会超时。
      await tester.binding.setSurfaceSize(const Size(420, 900));
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(380, 900));
      await tester.pumpAndSettle();

      final indicator = find.byKey(const Key('classic-tab-underline'));
      expect(
        tester.getCenter(indicator).dx,
        closeTo(tester.getCenter(find.text('书架')).dx, 1.0),
      );
      await tester.binding.setSurfaceSize(null);
    });

    for (final (initial, target) in [(0, 1), (1, 0), (1, 2), (2, 1)]) {
      testWidgets('书架连续滑动 $initial 到 $target：邻页接管时不二次入场或纵跳', (tester) async {
        await _size(tester);
        await tester.pumpWidget(_app(_style(), disableAnimations: false));
        await tester.pumpAndSettle();
        const labels = ['书架', '浏览历史', '收藏'];
        const notices = ['书架暂无书籍', '未找到相关内容', '暂无收藏内容'];
        // 先记录目标页静止时的位置，确保分页落位后的布局一致。
        await tester.tap(find.text(labels[target]));
        await tester.pumpAndSettle();
        final expected = tester.getRect(find.text(notices[target]));
        await tester.tap(find.text(labels[initial]));
        await tester.pumpAndSettle();
        final area = find.byType(TabSwipeArea);
        final direction = target > initial ? 1 : -1;
        final gesture = await tester.startGesture(tester.getCenter(area));
        // 先走一段不到半页：邻页已经是真实页面，跟着手指进入视口。
        for (var frame = 0; frame < 12; frame++) {
          await gesture.moveBy(Offset(-10.0 * direction, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.text(notices[target]), findsOneWidget);
        expect(tester.widget<TabSwipeArea>(area).index, initial);
        final halfway = tester.getRect(find.text(notices[target]));
        expect(
          (halfway.left - expected.left) * direction,
          greaterThan(0),
          reason: '邻页应该还没到位，正在从另一侧进入',
        );
        var previous = halfway.left;
        // 继续拖过半页再松手：真正提交到目标页。
        for (var frame = 0; frame < 14; frame++) {
          await gesture.moveBy(Offset(-10.0 * direction, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        var committed = false;
        for (var frame = 0; frame < 40; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final swipe = tester.widget<TabSwipeArea>(area);
          final rect = tester.getRect(find.text(notices[target]));
          expect(
            rect.top,
            closeTo(expected.top, .5),
            reason: '第 $frame 帧工具栏显隐使目标内容纵跳',
          );
          expect((rect.left - previous) * direction, lessThanOrEqualTo(.5));
          if (swipe.index == target) committed = true;
          previous = rect.left;
        }
        expect(committed, isTrue);
        expect(
          tester.getRect(find.text(notices[target])).left,
          closeTo(expected.left, .5),
          reason: '落位后应直接停在目标位置，不再二次入场',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('书架邻页预览使用目标分类，撤回与提交均保留历史滚动位置', (tester) async {
      await _size(tester);
      await tester.runAsync(() async {
        await ClassicShelfLayout.instance.load();
        await ClassicShelfLayout.instance.setLayout(BookshelfLayout.list);
        await ShelfStore.instance.add(_item());
        final group = await ShelfGroupStore.instance.addGroup('历史分组');
        for (var i = 0; i < 24; i++) {
          await LibraryStore.instance.addHistory({
            'id': 'history-$i',
            'title': '历史条目$i',
            'kind': 'book',
          });
        }
        await ShelfGroupStore.instance.assignKeys([
          for (var i = 0; i < 24; i++) 'book:history-$i',
        ], group);
        await LibraryStore.instance.addHistory({
          'id': 'outside',
          'title': '组外条目',
          'kind': 'book',
        });
        await ShelfViewStore.instance.load();
        await ShelfViewStore.instance.setCategoryOf(
          ShelfTabScope.history,
          group,
        );
      });
      await tester.pumpWidget(_app(_style(), disableAnimations: false));
      await tester.pumpAndSettle();
      final history = find.byKey(const PageStorageKey('classic-shelf-list-1'));
      // 保活页留在 keep-alive 桶里（offstage），断言滚动位置时要连它一起找。
      final keptHistory = find.byKey(
        const PageStorageKey('classic-shelf-list-1'),
        skipOffstage: false,
      );
      ScrollPosition historyPosition() => tester
          .state<ScrollableState>(
            find.descendant(
              of: keptHistory,
              matching: find.byType(Scrollable),
              skipOffstage: false,
            ),
          )
          .position;
      await tester.tap(find.text('浏览历史'));
      await tester.pumpAndSettle();
      expect(find.text('组外条目'), findsNothing);
      historyPosition().jumpTo(400);
      await tester.pumpAndSettle();
      await tester.tap(find.text('书架'));
      await tester.pumpAndSettle();

      for (final cancel in [true, false]) {
        final gesture = await tester.startGesture(const Offset(200, 500));
        // 先走不到半页：目标页已经建出来，且用的是「浏览历史」自己的分类。
        for (var frame = 0; frame < 12; frame++) {
          await gesture.moveBy(const Offset(-10, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(history, findsOneWidget);
        expect(historyPosition().pixels, closeTo(400, .1));
        expect(find.text('组外条目'), findsNothing);
        expect(find.text('已筛选 · 历史分组'), findsOneWidget);
        expect(tester.widget<TabSwipeArea>(find.byType(TabSwipeArea)).index, 0);
        if (cancel) {
          // 手指拉回切换阈值内并停住，再松手撤回这次切页。
          await gesture.moveBy(const Offset(140, 0));
          await tester.pump(const Duration(milliseconds: 200));
        } else {
          // 继续拖过半页，松手后停到「浏览历史」。
          for (var frame = 0; frame < 14; frame++) {
            await gesture.moveBy(const Offset(-10, 0));
            await tester.pump(const Duration(milliseconds: 16));
          }
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          tester.widget<TabSwipeArea>(find.byType(TabSwipeArea)).index,
          cancel ? 0 : 1,
        );
        if (cancel) {
          // 撤回后历史页退回保活桶：不在屏上，但实例还在；滚动位置由下一轮
          // 拖出来时的断言确认没丢。
          expect(history, findsNothing);
          expect(keptHistory, findsOneWidget);
        } else {
          expect(history, findsOneWidget);
          expect(historyPosition().pixels, closeTo(400, .1));
        }
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('书架下划线落在标签正中心，切换后跟随', (tester) async {
      await _size(tester);
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item());
      });
      final style = _style();
      await tester.pumpWidget(_app(style));
      await tester.pumpAndSettle();

      final underline = find.byKey(const Key('classic-tab-underline'));
      expect(underline, findsOneWidget);

      // The underline sits on the centre of the selected tab label.
      final shelfLabel = tester.getRect(find.text('书架'));
      final bar = tester.getRect(underline);
      expect(
        bar.center.dx,
        moreOrLessEquals(shelfLabel.center.dx, epsilon: 2),
        reason: '下划线必须落在标签正中心',
      );

      // After switching, it follows the new label.
      await tester.tap(find.text('浏览历史'));
      await tester.pumpAndSettle();
      final nextLabel = tester.getRect(find.text('浏览历史'));
      final nextBar = tester.getRect(underline);
      expect(
        nextBar.center.dx,
        moreOrLessEquals(nextLabel.center.dx, epsilon: 2),
        reason: '切换后下划线必须落在新标签正中心',
      );
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
        // The header row is end-aligned; both glyph centers must sit on the
        // same baseline (the more button uses the same 48px box as the M3
        // IconButton the search button renders as).
        expect(
          (tester.getCenter(find.byIcon(LucideIcons.search)).dy -
                  tester.getCenter(find.byIcon(LucideIcons.ellipsis)).dy)
              .abs(),
          lessThan(1),
        );
        expect(find.text('今日已读0分钟'), findsOneWidget);
        for (final name in ['grid', 'double', 'list']) {
          expect(find.byKey(Key('shelf-layout-$name')), findsOneWidget);
        }
        // The underline is drawn once for the whole row now, so it can slide
        // between the tabs; it is 26dp wide and uses the accent colour.
        final underline = tester.widget<AnimatedPositioned>(
          find.byKey(const Key('classic-tab-underline')),
        );
        expect(underline.width, 26);
        expect(underline.height, 3);
        final underlineBox = tester.getRect(
          find.byKey(const Key('classic-tab-underline')),
        );
        final shelfTab = tester.getRect(find.text('书架'));
        expect(
          underlineBox.center.dx,
          moreOrLessEquals(shelfTab.center.dx, epsilon: 2),
          reason: 'the underline must sit on the selected tab',
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
      'collection empty: manju filter flips the action copy and the notice sits above the screen center',
      (tester) async {
        await _size(tester);
        final style = _style();
        await tester.pumpWidget(_app(style));
        await tester.pumpAndSettle();
        await tester.tap(find.text('收藏'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('library-collection-filter-manju')),
        );
        await tester.pumpAndSettle();
        expect(find.text('暂无漫剧'), findsOneWidget);
        expect(find.text('找漫剧'), findsOneWidget);
        expect(find.text('找短剧'), findsNothing);
        // The header (tabs + toolbar) already takes ~110dp, so the notice
        // block must not sink below the screen's visual center (450 at this
        // surface size).
        final block = tester.getRect(
          find
              .ancestor(
                of: find.byKey(const Key('collection-find-drama-button')),
                matching: find.byType(Column),
              )
              .first,
        );
        expect(block.center.dy, lessThan(490));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'collection empty notice keeps one anchor with and without the filter row',
      (tester) async {
        await _size(tester);
        final style = _style();
        await tester.pumpWidget(_app(style));
        await tester.pumpAndSettle();
        await tester.tap(find.text('收藏'));
        await tester.pumpAndSettle();
        Rect block() => tester.getRect(
          find
              .ancestor(
                of: find.byKey(const Key('collection-find-drama-button')),
                matching: find.byType(Column),
              )
              .first,
        );
        final plainCenter = block().center.dy;

        // The “已筛选 · 清除筛选” row pushes the remaining area down by
        // 40dp; the compensated anchor must keep the notice on the same
        // on-screen center as the header-free view.
        await tester.tap(
          find.byKey(const Key('library-collection-filter-manju')),
        );
        await tester.pumpAndSettle();
        expect(find.text('暂无漫剧'), findsOneWidget);
        final filteredCenter = block().center.dy;
        expect((filteredCenter - plainCenter).abs(), lessThan(2));
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

    testWidgets('分组胶囊：文案/激活态/重命名跟随分组，archive 不显示 classic 胶囊', (tester) async {
      await _size(tester);
      late String group;
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item());
        group = await ShelfGroupStore.instance.addGroup('想读');
        await ShelfGroupStore.instance.addGroup('睡前');
        await ShelfGroupStore.instance.assignKeys(['book:123'], group);
      });
      final style = _style();
      await tester.pumpWidget(_app(style));
      await tester.pumpAndSettle();

      final chip = find.byKey(const Key('shelf-group-chip'));
      expect(chip, findsOneWidget);
      expect(
        find.descendant(of: chip, matching: find.text('全部书籍')),
        findsOneWidget,
      );
      expect(find.byTooltip('书架分组：全部书籍'), findsOneWidget);
      expect(
        tester.getSemantics(chip).flagsCollection.isSelected,
        Tristate.isFalse,
      );

      // 胶囊就是分组入口：点开现有的分类弹层。
      await tester.tap(chip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('书籍分类'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // 选择分组由既有的 ShelfViewStore 驱动；测试里在真实异步区写入，
      // 避免 Hive/偏好写队列落在 fake-async 区里不完成。
      await tester.runAsync(
        () => ShelfViewStore.instance.setCategoryOf(ShelfTabScope.shelf, group),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.descendant(of: chip, matching: find.text('想读')),
        findsOneWidget,
      );
      expect(find.byTooltip('书架分组：想读'), findsOneWidget);
      expect(
        tester.getSemantics(chip).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      expect(
        tester
            .widget<Text>(find.descendant(of: chip, matching: find.text('想读')))
            .style!
            .color,
        HomePalette.accent,
      );
      expect(find.byType(BookshelfGridCard), findsOneWidget);

      // 分组在别处改名：`_groupChanges` 监听让胶囊文案跟着回真。
      await tester.runAsync(
        () => ShelfGroupStore.instance.renameGroup(group, '在读'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.descendant(of: chip, matching: find.text('在读')),
        findsOneWidget,
      );
      expect(find.byTooltip('书架分组：在读'), findsOneWidget);

      // archive 分支不渲染经典胶囊；筛选本身不受版式切换影响。
      style.value = const AppStyleTokens.archive();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shelf-group-chip')), findsNothing);
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);
      expect(ShelfViewStore.instance.categoryOf(ShelfTabScope.shelf), group);

      style.value = const AppStyleTokens.classic();
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: chip, matching: find.text('在读')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(chip).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      expect(find.byType(BookshelfGridCard), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('分组筛选后列表过滤，空分组显示组名空态', (tester) async {
      await _size(tester);
      late String filled;
      late String empty;
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item());
        filled = await ShelfGroupStore.instance.addGroup('想读');
        empty = await ShelfGroupStore.instance.addGroup('睡前');
        await ShelfGroupStore.instance.assignKeys(['book:123'], filled);
      });
      await tester.pumpWidget(_app(_style()));
      await tester.pumpAndSettle();

      final chip = find.byKey(const Key('shelf-group-chip'));
      await tester.runAsync(
        () => ShelfViewStore.instance.setCategoryOf(ShelfTabScope.shelf, empty),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(BookshelfGridCard), findsNothing);
      expect(find.text('「睡前」暂无书籍'), findsOneWidget);
      expect(find.text('未找到相关内容'), findsNothing);
      expect(
        find.descendant(of: chip, matching: find.text('睡前')),
        findsOneWidget,
      );

      await tester.runAsync(
        () =>
            ShelfViewStore.instance.setCategoryOf(ShelfTabScope.shelf, filled),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(BookshelfGridCard), findsOneWidget);
      expect(find.text('测试书籍'), findsOneWidget);
      expect(
        find.descendant(of: chip, matching: find.text('想读')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('空书架选中分组时优先显示组名空态', (tester) async {
      await _size(tester);
      late String group;
      await tester.runAsync(() async {
        group = await ShelfGroupStore.instance.addGroup('睡前');
      });
      await tester.pumpWidget(_app(_style()));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => ShelfViewStore.instance.setCategoryOf(ShelfTabScope.shelf, group),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('「睡前」暂无书籍'), findsOneWidget);
      expect(find.text('书架暂无书籍'), findsNothing);
      expect(find.text('未找到相关内容'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('分组有书但来源筛选隐藏时保留筛选空态', (tester) async {
      await _size(tester);
      late String group;
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item());
        group = await ShelfGroupStore.instance.addGroup('想读');
        await ShelfGroupStore.instance.assignKeys(['book:123'], group);
      });
      await tester.pumpWidget(_app(_style()));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await ShelfViewStore.instance.setCategoryOf(ShelfTabScope.shelf, group);
        await ShelfViewStore.instance.setSource(ShelfSourceFilter.local);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('没有符合筛选的书籍'), findsOneWidget);
      expect(find.text('「想读」暂无书籍'), findsNothing);
      expect(find.text('未找到相关内容'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('320dp + 2x 字号下工具栏同一行不溢出，长分组名只省略', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late String group;
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item());
        group = await ShelfGroupStore.instance.addGroup('分组名称' * 6);
        await ShelfGroupStore.instance.assignKeys(['book:123'], group);
      });
      setSingleChapterPrefs({
        'shelfLayout': 'shelfGrid',
        'shelfCategory': group,
      });
      await ShelfViewStore.instance.load();
      await tester.pumpWidget(
        _app(
          _style(),
          size: const Size(320, 800),
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pumpAndSettle();

      final chip = find.byKey(const Key('shelf-group-chip'));
      expect(chip, findsOneWidget);
      expect(tester.getSize(chip).width, lessThanOrEqualTo(148));
      final label = tester.widget<Text>(
        find.descendant(of: chip, matching: find.text('分组名称' * 6)),
      );
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      expect(find.text('今日已读0分钟'), findsOneWidget);
      for (final name in ['grid', 'double', 'list']) {
        expect(find.byKey(Key('shelf-layout-$name')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('3x 辅助功能字号下筛选行钳制字号，定高契约不溢出', (tester) async {
      await _size(tester);
      late String group;
      await tester.runAsync(() async {
        await ShelfStore.instance.add(_item());
        group = await ShelfGroupStore.instance.addGroup('测试分组');
        await ShelfGroupStore.instance.assignKeys(['book:123'], group);
      });
      setSingleChapterPrefs({
        'shelfLayout': 'shelfGrid',
        'shelfCategory': group,
      });
      await ShelfViewStore.instance.load();
      await tester.pumpWidget(
        _app(_style(), textScaler: const TextScaler.linear(3)),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const Key('classic-shelf-active-filters'));
      expect(row, findsOneWidget);
      expect(tester.getSize(row).height, ShelfTokens.filterStatusHeight);
      // 行内文字（含 TextButton 标签）必须被钳制在 1.3 倍内：3x 下
      // 标签固有高度 ≈60px 会溢出 40 定高向行外绘制（纯视觉、无异常），
      // 钳制后 ≈26px 定高仍成立。
      final label = tester.element(find.text('清除筛选'));
      expect(
        MediaQuery.textScalerOf(label).scale(14),
        lessThanOrEqualTo(14 * 1.3 + 0.01),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
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
  Size size = const Size(400, 900),
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = true,
}) => ValueListenableBuilder<AppStyleTokens>(
  valueListenable: style,
  child: page ?? LibraryPage(cacheStore: MemoryChapterCache()),
  builder: (context, tokens, child) => MaterialApp(
    themeAnimationDuration: Duration.zero,
    theme: ThemeData(extensions: [tokens]),
    navigatorObservers: [?observer],
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        disableAnimations: disableAnimations,
        textScaler: textScaler,
      ),
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
