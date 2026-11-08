import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/author_profile.dart';
import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/author_page.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/shuqi_detail_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/app_ui/content_anchor.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/fakes.dart';

/// 经典 ⇄ 档案 切换后的内容连续性 (PR #292 审查 P1/P2).
///
/// The two layouts are different widget trees: the ScrollPosition is torn down
/// on every switch. These tests scroll, switch one way and back, and assert the
/// page comes back to the same *content* (section or row), without re-requesting
/// data or replacing the page State / route.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory hiveDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    hiveDirectory = await Directory.systemTemp.createTemp('fqapp-switch-');
    Hive.init(hiveDirectory.path);
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDirectory.existsSync()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  group('novel scroll continuity', () {
    testWidgets('经典 keeps the visible section across 档案 and back', (
      tester,
    ) async {
      final requests = <String>[];
      final observer = _RouteObserver();
      final store = await _pumpDetail(
        tester,
        requests: requests,
        observer: observer,
        size: const Size(360, 400),
      );
      addTearDown(store.dispose);

      // Park the 目录 section exactly at the top: the section exists in both
      // layouts, so the anchor is the content the user is looking at.
      final reviews = find.text('目录');
      expect(reviews, findsOneWidget);
      await _scrollToTop(tester, reviews, 'detail_scroll');
      final classicOffset = _offset(tester, 'detail_scroll');
      expect(classicOffset, greaterThan(100));
      expect(_viewportDy(tester, reviews, 'detail_scroll').abs(), lessThan(4));
      final state = tester.state(find.byType(DetailPage));
      final route = observer.lastRoute;

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(find.byType(WenkuPage), findsOneWidget);
      // Same section, still at the top edge — not the top of the page.
      expect(_offset(tester, 'detail_scroll'), greaterThan(100));
      expect(
        _viewportDy(tester, reviews, 'detail_scroll').abs(),
        lessThan(20),
        reason: '档案 must land on the same section, not at offset 0',
      );
      expect(requests, ['小说:book', '小说:book']);
      expect(identical(tester.state(find.byType(DetailPage)), state), isTrue);
      expect(identical(observer.lastRoute, route), isTrue);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(find.byType(WenkuPage), findsNothing);
      expect(_offset(tester, 'detail_scroll'), greaterThan(100));
      expect(
        _viewportDy(tester, reviews, 'detail_scroll').abs(),
        lessThan(20),
        reason: 'returning to 经典 must keep the same section in view',
      );
      expect(requests, ['小说:book', '小说:book']);
      expect(identical(tester.state(find.byType(DetailPage)), state), isTrue);
    });

    testWidgets('deep inside 档案 catalogue 经典 falls back to the 目录 preview', (
      tester,
    ) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.archive);
      await _size(tester);
      await tester.pumpWidget(
        _host(
          store: store,
          home: DetailPage(
            item: _book,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            detailLoader: (id, {String tab = '小说'}) async => {
              'data': {'abstract': _longSummary},
            },
            directoryLoader: (id, {String tab = '小说'}) async => [
              _chapters(60, volumeNames: false),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll far into the inline catalogue.
      final deep = find.byKey(
        const ValueKey('detail-directory-entry-40'),
        skipOffstage: false,
      );
      for (var i = 0; i < 40 && deep.evaluate().isEmpty; i++) {
        await tester.drag(
          find.byKey(const Key('detail_scroll')),
          const Offset(0, -300),
        );
        await tester.pump();
      }
      expect(deep, findsWidgets);
      expect(_offset(tester, 'detail_scroll'), greaterThan(1500));

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The classic page only previews current ±1, so the fallback is the whole
      // 目录 section (the old preview heading), not a fabricated row.
      final heading = find.text('目录');
      expect(heading, findsOneWidget);
      final dy = _viewportDy(tester, heading, 'detail_scroll');
      expect(dy, greaterThanOrEqualTo(0));
      // The classic body is short: it scrolls as far as the layout allows, and
      // the 目录 preview stays visible instead of silently restarting at the hero.
      expect(dy, lessThan(450));
      expect(_offset(tester, 'detail_scroll'), greaterThan(0));
      expect(find.byKey(const Key('detail_preview_chapters')), findsOneWidget);
    });

    testWidgets('经典 expands the synopsis and keeps it open both ways', (
      tester,
    ) async {
      final store = await _pumpDetail(tester);
      addTearDown(store.dispose);

      final toggle = find.byKey(const Key('detail_description_toggle'));
      expect(toggle, findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(_synopsisMaxLines(tester), isNull);

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(_synopsisMaxLines(tester), isNull);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(_synopsisMaxLines(tester), isNull);

      // The very same value drives both renderers: folding in one folds both.
      await tester.tap(find.byKey(const Key('detail_description_toggle')));
      await tester.pumpAndSettle();
      expect(find.text('展开全部'), findsOneWidget);
      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(find.text('展开全部'), findsOneWidget);
      expect(_synopsisMaxLines(tester), 3);
    });

    testWidgets('档案 expands the synopsis and keeps it open in 经典', (
      tester,
    ) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.archive);
      await _size(tester);
      await tester.pumpWidget(_host(store: store, home: _detail(_longSummary)));
      await tester.pumpAndSettle();

      final toggle = find.byKey(const Key('detail_description_toggle'));
      await tester.ensureVisible(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(_synopsisMaxLines(tester), isNull);
    });

    testWidgets('a changed synopsis collapses again', (tester) async {
      var calls = 0;
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester);
      await tester.pumpWidget(
        _host(
          store: store,
          home: DetailPage(
            item: _book,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            detailLoader: (id, {String tab = '小说'}) async {
              calls++;
              return {
                'data': {'abstract': calls == 1 ? _longSummary : '另一本书的简介。'},
              };
            },
            directoryLoader: (id, {String tab = '小说'}) async => [_chapters(3)],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final toggle = find.byKey(const Key('detail_description_toggle'));
      await tester.ensureVisible(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);

      // Pull to refresh: same book, different payload → collapsed again.
      await tester.drag(
        find.byKey(const Key('detail_scroll')),
        const Offset(0, 2000),
      );
      await tester.pumpAndSettle();
      await tester.fling(
        find.byKey(const Key('detail_scroll')),
        const Offset(0, 320),
        1000,
      );
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('另一本书的简介。'), findsOneWidget);
      expect(find.text('收起'), findsNothing);
    });
  });

  group('书旗 scroll continuity', () {
    testWidgets('keeps the same chapter across 经典 ⇄ 档案', (tester) async {
      final calls = <String>[];
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester);
      await tester.pumpWidget(
        _host(
          store: store,
          home: _shuqiPage(calls: calls),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('shuqi-detail-scroll')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(_offset(tester, 'shuqi-detail-scroll'), greaterThan(300));
      final before = _topShuqiRow(tester);
      expect(before, isNotNull);
      final state = tester.state(find.byType(ShuqiDetailPage));
      final chapter = before!.index;
      final rowDy = _rowDy(tester, chapter);
      expect(rowDy, isNotNull);

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(find.byType(WenkuPage), findsOneWidget);
      // Same chapter id, same place in the viewport — not the top of the list.
      expect(_rowDy(tester, chapter), isNotNull);
      expect((_rowDy(tester, chapter)! - rowDy!).abs(), lessThan(30));
      expect(_offset(tester, 'shuqi-detail-scroll'), greaterThan(300));
      expect(calls, ['book:34078', 'toc:34078']);
      expect(
        identical(tester.state(find.byType(ShuqiDetailPage)), state),
        isTrue,
      );

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(_rowDy(tester, chapter), isNotNull);
      expect((_rowDy(tester, chapter)! - rowDy).abs(), lessThan(30));
      expect(calls, ['book:34078', 'toc:34078']);
      expect(
        identical(tester.state(find.byType(ShuqiDetailPage)), state),
        isTrue,
      );
    });
  });

  group('deep lazy rows', () {
    testWidgets('书旗 keeps a chapter 400 rows in, both ways', (tester) async {
      final calls = <String>[];
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester);
      await tester.pumpWidget(
        _host(
          store: store,
          home: _shuqiPage(calls: calls, chapters: 400),
        ),
      );
      await tester.pumpAndSettle();

      // 2000px deep: the target chapter is far outside the first built batch,
      // so the incoming layout has to locate it by index before snapping.
      final controller = tester
          .widget<CustomScrollView>(
            find.byKey(const Key('shuqi-detail-scroll')),
          )
          .controller!;
      controller.jumpTo(2000);
      await tester.pumpAndSettle();
      final before = _topShuqiRow(tester);
      expect(before, isNotNull);
      expect(before!.index, greaterThan(30), reason: 'must be a deep row');
      final chapter = before.index;
      final state = tester.state(find.byType(ShuqiDetailPage));

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      // The row was not mounted at first; it must be built and placed back at
      // its old depth instead of jumping to the 目录 header.
      final archived = _rowDy(tester, chapter);
      expect(archived, isNotNull, reason: 'the chapter row must be built');
      expect((archived! - before.dy).abs(), lessThan(60));
      expect(_offset(tester, 'shuqi-detail-scroll'), greaterThan(1500));
      expect(calls, ['book:34078', 'toc:34078']);
      expect(
        identical(tester.state(find.byType(ShuqiDetailPage)), state),
        isTrue,
      );

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      final back = _rowDy(tester, chapter);
      expect(back, isNotNull, reason: 'the chapter row must be built again');
      expect(back, lessThan(600));
      expect(calls, ['book:34078', 'toc:34078']);
      expect(
        identical(tester.state(find.byType(ShuqiDetailPage)), state),
        isTrue,
      );
    });

    testWidgets('作者 keeps a work 120 rows in, both ways', (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester, const Size(400, 600));
      var calls = 0;
      await tester.pumpWidget(
        _host(
          store: store,
          home: AuthorPage(
            authorId: _author.id,
            fallbackName: _author.name,
            loader: (_) async {
              calls++;
              return _author;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final controller = tester
          .widget<CustomScrollView>(find.byKey(const Key('author_scroll')))
          .controller!;
      controller.jumpTo(4100);
      await tester.pumpAndSettle();
      final before = _topAuthorWork(tester);
      expect(before, isNotNull);
      final index = _author.works.indexWhere((work) => work.id == before!.id);
      expect(index, greaterThan(30), reason: 'must be a deep work');
      final state = tester.state(find.byType(AuthorPage));
      final anchor = _capturedAnchor(
        tester,
        find.byType(AuthorPage),
        'author_scroll',
        _authorIndexOf,
      );
      final classicViewport = _visibleViewport(tester, 'author_scroll');
      final classicRect = _anchorRect(tester, anchor);
      expect(classicRect, isNotNull);
      expect(classicRect!.bottom, greaterThan(classicViewport.top));
      final classicTop = classicRect.top - classicViewport.top;

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      // Grid (3 columns) → list: the row is a different height, but the same
      // work is built and still intersects the viewport.
      final archivedViewport = _visibleViewport(tester, 'author_scroll');
      final archivedRect = _anchorRect(tester, anchor);
      expect(archivedRect, isNotNull, reason: 'the work row must be built');
      expect(
        archivedRect!.bottom,
        greaterThan(archivedViewport.top),
        reason: 'the captured work must stay on screen',
      );
      expect(archivedRect.top, lessThan(archivedViewport.bottom));
      expect(_offset(tester, 'author_scroll'), greaterThan(2000));
      expect(calls, 1);
      expect(identical(tester.state(find.byType(AuthorPage)), state), isTrue);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      // Back in the grid the anchored work sits at its old depth again (the
      // depth is converted by row height, so the round trip is stable).
      final backViewport = _visibleViewport(tester, 'author_scroll');
      final backRect = _anchorRect(tester, anchor);
      expect(backRect, isNotNull);
      expect(backRect!.bottom, greaterThan(backViewport.top));
      expect(
        (backRect.top - backViewport.top - classicTop).abs(),
        lessThan(80),
        reason: 'the round trip must come back to the same depth',
      );
      expect(_offset(tester, 'author_scroll'), greaterThan(2000));
      expect(calls, 1);
      expect(identical(tester.state(find.byType(AuthorPage)), state), isTrue);
    });
  });

  group('row height changes', () {
    for (final fraction in [0.55, 0.88]) {
      testWidgets('作者 grid ${(fraction * 100).round()}% 行内深度：锚点行仍在视口内并可往返', (
        tester,
      ) async {
        final store = AppThemeStyleStore();
        addTearDown(store.dispose);
        await store.select(AppThemeStyle.classic);
        await _size(tester, const Size(400, 600));
        await tester.pumpWidget(
          _host(
            store: store,
            home: AuthorPage(
              authorId: _author.id,
              fallbackName: _author.name,
              loader: (_) async => _author,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Grid geometry at the top: pitch = card extent + row spacing.
        final viewport = _visibleViewport(tester, 'author_scroll');
        final cardExtent = _anchorRect(tester, 'works/work:work-0')!.height;
        final pitch = _workDy(tester, 'work-3')! - _workDy(tester, 'work-0')!;
        final controller = tester
            .widget<CustomScrollView>(find.byKey(const Key('author_scroll')))
            .controller!;
        controller.jumpTo(pitch * 16 + cardExtent * fraction);
        await tester.pumpAndSettle();

        final anchor = _capturedAnchor(
          tester,
          find.byType(AuthorPage),
          'author_scroll',
          _authorIndexOf,
        );
        final classicRect = _anchorRect(tester, anchor);
        expect(classicRect, isNotNull);
        final depth = viewport.top - classicRect!.top;
        expect(depth, greaterThan(0), reason: 'inside a row, not the gap');
        expect(classicRect.bottom, greaterThan(viewport.top));

        await store.select(AppThemeStyle.archive);
        await tester.pumpAndSettle();
        final archivedViewport = _visibleViewport(tester, 'author_scroll');
        final archivedRect = _anchorRect(tester, anchor);
        expect(archivedRect, isNotNull, reason: 'the row must be built');
        // The list row is ~109dp tall, the grid card ~231dp: the same pixel
        // depth would park the row above the viewport.
        expect(
          archivedRect!.bottom,
          greaterThan(archivedViewport.top),
          reason: 'the captured row must still intersect the viewport',
        );
        expect(archivedRect.top, lessThan(archivedViewport.bottom));
        final archivedDepth = archivedViewport.top - archivedRect.top;
        expect(archivedDepth, lessThan(depth));

        await store.select(AppThemeStyle.classic);
        await tester.pumpAndSettle();
        final backViewport = _visibleViewport(tester, 'author_scroll');
        final backRect = _anchorRect(tester, anchor);
        expect(backRect, isNotNull);
        expect(backRect!.bottom, greaterThan(backViewport.top));
        expect(
          (backRect.top - backViewport.top - (classicRect.top - viewport.top))
              .abs(),
          lessThan(80),
          reason: 'the round trip must come back to the same depth',
        );
      });
    }

    testWidgets('书旗 高行→矮行：archive 行内深度不把章节推离视口', (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.archive);
      await _size(tester);
      await tester.pumpWidget(
        _host(store: store, home: _shuqiPage(chapters: 400)),
      );
      await tester.pumpAndSettle();

      // Classic rows are shorter than the archive ones. Land near the bottom of
      // an archive row so the copied pixel depth would clear the classic row.
      final row0Top = _rowDy(tester, 0)!;
      final archiveExtent = _anchorRect(tester, 'directory/chapter:c0')!.height;
      final pitch = _rowDy(tester, 1)! - _rowDy(tester, 0)!;
      expect(pitch, greaterThan(40));
      expect(archiveExtent, greaterThan(40));
      final controller = tester
          .widget<CustomScrollView>(
            find.byKey(const Key('shuqi-detail-scroll')),
          )
          .controller!;
      controller.jumpTo(row0Top + pitch * 20 + archiveExtent - 4);
      await tester.pumpAndSettle();

      final anchor = _capturedAnchor(
        tester,
        find.byType(ShuqiDetailPage),
        'shuqi-detail-scroll',
        _shuqiIndexOf,
      );
      final archiveViewport = _visibleViewport(tester, 'shuqi-detail-scroll');
      final archiveRect = _anchorRect(tester, anchor);
      expect(archiveRect, isNotNull);
      final depth = archiveViewport.top - archiveRect!.top;
      expect(depth, closeTo(archiveExtent - 4, 1));

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      final classicViewport = _visibleViewport(tester, 'shuqi-detail-scroll');
      final classicRect = _anchorRect(tester, anchor);
      expect(classicRect, isNotNull);
      // Precondition for the bug: the copied pixels would clear the shorter row.
      expect(depth, greaterThan(classicRect!.height));
      expect(
        classicRect.bottom,
        greaterThan(classicViewport.top),
        reason: 'the chapter row must stay on screen',
      );
      expect(classicRect.top, lessThan(classicViewport.bottom));

      // And the round trip returns to (about) the same in-row depth.
      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      final backViewport = _visibleViewport(tester, 'shuqi-detail-scroll');
      final backRect = _anchorRect(tester, anchor);
      expect(backRect, isNotNull);
      expect(backRect!.bottom, greaterThan(backViewport.top));
      expect(
        (backRect.top -
                backViewport.top -
                (archiveRect.top - archiveViewport.top))
            .abs(),
        lessThan(80),
      );
    });
  });

  group('floating header occlusion', () {
    testWidgets('书旗 classic→档案：章节落在浮动头栏下方且真的可点', (tester) async {
      final observer = _RouteObserver();
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester, const Size(393, 700));
      await tester.pumpWidget(
        _host(
          store: store,
          observers: [observer],
          home: _shuqiPage(chapters: 80),
        ),
      );
      await tester.pumpAndSettle();

      // Park chapter 21 (index 20) at the visible top of the classic body.
      final controller = tester
          .widget<CustomScrollView>(
            find.byKey(const Key('shuqi-detail-scroll')),
          )
          .controller!;
      final rowTop = _rowDy(tester, 0)!;
      final pitch = _rowDy(tester, 1)! - rowTop;
      controller.jumpTo(rowTop + pitch * 20);
      await tester.pumpAndSettle();
      expect(_rowDy(tester, 20), closeTo(0, 1));

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('shuqi-chapter-20'));
      expect(row, findsOneWidget);
      final viewport = tester.getRect(
        find.byKey(const Key('shuqi-detail-scroll')),
      );
      final rect = tester.getRect(row);
      // The row must sit *below* the floating glass bar (FrostedHeader's 56dp
      // toolbar, no status bar in this test), not under it.
      expect(rect.top, greaterThanOrEqualTo(viewport.top + _glassBar - 1));
      expect(rect.top, lessThan(viewport.top + _glassBar + 40));
      expect(rect.height, greaterThan(20));

      // And it is really tappable there: a tap opens the reader on that chapter.
      await tester.tap(row);
      await tester.idle();
      final context = tester.element(find.byType(ShuqiDetailPage));
      final route = observer.lastRoute;
      expect(route, isA<MaterialPageRoute>());
      final page = (route! as MaterialPageRoute).builder(context);
      expect(page, isA<ReaderPage>());
      expect((page as ReaderPage).startIndex, 20);
      expect(page.bookId, 'shuqi:34078');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('作者 classic→档案：作品行在浮动头栏下方且可点', (tester) async {
      final observer = _RouteObserver();
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester, const Size(400, 700));
      await tester.pumpWidget(
        _host(
          store: store,
          observers: [observer],
          home: AuthorPage(
            authorId: _author.id,
            fallbackName: _author.name,
            loader: (_) async => _author,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final controller = tester
          .widget<CustomScrollView>(find.byKey(const Key('author_scroll')))
          .controller!;
      final rowTop = _workDy(tester, 'work-0')!;
      final pitch = _workDy(tester, 'work-3')! - rowTop;
      controller.jumpTo(rowTop + pitch * 6);
      await tester.pumpAndSettle();
      final before = _topAuthorWork(tester);
      expect(before, isNotNull);
      expect(before!.dy, closeTo(0, 1));

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      final archived = _topAuthorWork(tester);
      expect(archived, isNotNull);
      final viewport = tester.getRect(find.byKey(const Key('author_scroll')));
      final row = find.byKey(ValueKey('author_work_${archived!.id}'));
      expect(row, findsOneWidget);
      final rect = tester.getRect(row);
      expect(rect.top, greaterThanOrEqualTo(viewport.top + _glassBar - 1));
      expect(archived.dy, lessThan(40));

      await tester.tap(row);
      await tester.idle();
      final context = tester.element(find.byType(AuthorPage));
      final route = observer.lastRoute;
      expect(route, isA<MaterialPageRoute>());
      final page = (route! as MaterialPageRoute).builder(context);
      expect(page, isA<DetailPage>());
      expect((page as DetailPage).item.id, archived.id);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('状态栏安全区计入浮动头栏的可见顶部', (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester, const Size(393, 700));
      await tester.pumpWidget(
        _host(
          store: store,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 24),
                viewPadding: const EdgeInsets.only(top: 24),
              ),
              child: _shuqiPage(chapters: 80),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final controller = tester
          .widget<CustomScrollView>(
            find.byKey(const Key('shuqi-detail-scroll')),
          )
          .controller!;
      final rowTop = _rowDy(tester, 0)!;
      final pitch = _rowDy(tester, 1)! - rowTop;
      controller.jumpTo(rowTop + pitch * 20);
      await tester.pumpAndSettle();

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      // status bar 24 + glass toolbar 56.
      const statusBar = 24.0;
      final row = find.byKey(const ValueKey('shuqi-chapter-20'));
      final viewport = tester.getRect(
        find.byKey(const Key('shuqi-detail-scroll')),
      );
      expect(
        tester.getRect(row).top,
        greaterThanOrEqualTo(viewport.top + statusBar + _glassBar - 1),
      );
      expect(_rowDy(tester, 20), lessThan(40));

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      // The classic body starts below its own AppBar, the inset is 0 there.
      expect(_visibleInset(tester), 0);
      expect(_rowDy(tester, 20), closeTo(0, 1));
    });

    testWidgets('被其他 route 覆盖后返回仍停在页头下方', (tester) async {
      final store = await _pumpDetail(tester, size: const Size(393, 440));
      addTearDown(store.dispose);

      final directory = find.text('目录');
      expect(directory, findsOneWidget);
      await _scrollToTop(tester, directory, 'detail_scroll');
      expect(
        _viewportDy(tester, directory, 'detail_scroll').abs(),
        lessThan(4),
      );

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(
        _viewportDy(tester, directory, 'detail_scroll').abs(),
        lessThan(20),
      );

      // Cover the page with the directory sheet, then come back to it.
      await tester.tap(find.byKey(const Key('detail_directory_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_directory_search')), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail_directory_close')));
      await tester.pumpAndSettle();

      final viewport = tester.getRect(find.byKey(const Key('detail_scroll')));
      final rect = tester.getRect(directory);
      expect(rect.top, greaterThanOrEqualTo(viewport.top + _glassBar - 1));
      expect(
        _viewportDy(tester, directory, 'detail_scroll').abs(),
        lessThan(20),
      );
    });
  });

  group('author scroll continuity', () {
    testWidgets('keeps the same works in view across 经典 ⇄ 档案', (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester, const Size(400, 600));
      var calls = 0;
      await tester.pumpWidget(
        _host(
          store: store,
          home: AuthorPage(
            authorId: _author.id,
            fallbackName: _author.name,
            loader: (_) async {
              calls++;
              return _author;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('author_scroll')),
        const Offset(0, -420),
      );
      await tester.pumpAndSettle();
      expect(_offset(tester, 'author_scroll'), greaterThan(200));
      final before = _topAuthorWork(tester);
      expect(before, isNotNull);
      final state = tester.state(find.byType(AuthorPage));
      final work = before!.id;

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      // The anchor keeps the work it captured at the same viewport depth; the
      // neighbouring works shift because 经典 is a 3-column grid and 档案 a list,
      // so the check is "that work is still in view", not "same pixel line".
      expect(_offset(tester, 'author_scroll'), greaterThan(200));
      final archived = _workDy(tester, work);
      expect(archived, isNotNull);
      expect((archived! - before.dy).abs(), lessThan(2));
      expect(calls, 1);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(_offset(tester, 'author_scroll'), greaterThan(200));
      // The work that covered the top edge in 档案 is the anchor there; it is
      // placed back at the same depth in the grid, i.e. still on screen.
      final back = _workDy(tester, work);
      expect(back, isNotNull);
      expect(back!, greaterThan(-1));
      expect(back, lessThan(300));
      expect(calls, 1);
      expect(identical(tester.state(find.byType(AuthorPage)), state), isTrue);
    });
  });
}

/// `FrostedHeader.toolbarHeight`: the archive shells paint this glass bar over
/// the scrolling body, so its bottom edge is the first visible y.
const double _glassBar = 56;

const _longSummary =
    '苏狂身穿玄幻世界，激活无敌宗门系统，开局就召唤出了大帝境强者！\n'
    '只要招收天才进宗，还能继续抽取各类强者！\n'
    '而且弟子的修为精进，也能百倍返还给苏狂！\n'
    '于是，一段关于宗门、成长与奇遇的故事，就这样开始。\n'
    '多年以后，当苏狂坐在万古之巅回望，才发现最初那座破败的山门，'
    '才是所有传说真正开始的地方。';

Widget _host({
  required AppThemeStyleStore store,
  required Widget home,
  List<NavigatorObserver> observers = const [],
}) => ValueListenableBuilder<AppThemeStyle>(
  valueListenable: store,
  builder: (context, style, _) => MaterialApp(
    navigatorObservers: observers,
    theme: AppTheme.createTheme(Brightness.light, style: style),
    builder: (context, child) =>
        AppUiScope(store: store, child: child ?? const SizedBox.shrink()),
    home: home,
  ),
);

Future<void> _size(
  WidgetTester tester, [
  Size size = const Size(393, 600),
]) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
}

Widget _detail(String summary) => DetailPage(
  item: _book,
  readerStore: MemoryReaderStore(),
  chapterCache: MemoryChapterCache(),
  detailLoader: (id, {String tab = '小说'}) async => {
    'data': {'abstract': summary},
  },
  directoryLoader: (id, {String tab = '小说'}) async => [_chapters(30)],
);

Future<AppThemeStyleStore> _pumpDetail(
  WidgetTester tester, {
  List<String>? requests,
  _RouteObserver? observer,
  Size size = const Size(393, 600),
}) async {
  final store = AppThemeStyleStore();
  await store.select(AppThemeStyle.classic);
  await _size(tester, size);
  await tester.pumpWidget(
    _host(
      store: store,
      observers: observer == null ? const [] : [observer],
      home: DetailPage(
        item: _book,
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        extrasLoader: (_) async => const DetailExtras(
          comments: BookCommentPage(
            comments: [
              BookComment(id: 'c1', text: '很好看的一本书', userName: '读者甲'),
              BookComment(id: 'c2', text: '强烈推荐', userName: '读者乙'),
              BookComment(id: 'c3', text: '一口气读完', userName: '读者丙'),
            ],
            totalCount: 3,
          ),
        ),
        detailLoader: (id, {String tab = '小说'}) async {
          requests?.add('$tab:$id');
          return {
            'data': {'abstract': _longSummary, 'creation_status': '1'},
          };
        },
        directoryLoader: (id, {String tab = '小说'}) async {
          requests?.add('$tab:$id');
          return [_chapters(30)];
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

/// Scrolls [scrollKey] so [target] starts exactly at the viewport's top edge.
///
/// Uses the page's own controller instead of a drag: a gesture smaller than
/// the touch slop would not move the list at all.
Future<void> _scrollToTop(
  WidgetTester tester,
  Finder target,
  String scrollKey,
) async {
  final view = find.byKey(Key(scrollKey));
  final controller = tester.widget<CustomScrollView>(view).controller!;
  final dy = _viewportDy(tester, target, scrollKey);
  final position = controller.position;
  controller.jumpTo(
    (controller.offset + dy)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble(),
  );
  await tester.pumpAndSettle();
}

/// The anchor the page itself would capture at the current offset, using the
/// same helper and the same data-index resolver as the page.
String _capturedAnchor(
  WidgetTester tester,
  Finder page,
  String scrollKey,
  int? Function(String anchorId) indexOf,
) {
  final controller = tester
      .widget<CustomScrollView>(find.byKey(Key(scrollKey)))
      .controller!;
  final anchor = captureContentAnchor(
    tester.element(page),
    controller.position,
    indexOf: indexOf,
    visibleInset: _visibleInset(tester),
  );
  expect(anchor, isNotNull);
  return anchor!.id;
}

/// Distance from the scroll viewport's top edge to the first row that is not
/// hidden by the current shell: 0 for the classic AppBar-below body, the glass
/// header height for the archive body that scrolls underneath it.
double _visibleInset(WidgetTester tester) {
  final wenku = find.byType(WenkuPage);
  if (wenku.evaluate().isEmpty) return 0;
  return archiveChromeInset(tester.element(wenku.first));
}

/// Global rect of an anchor's row, or null when the row is not mounted.
Rect? _anchorRect(WidgetTester tester, String anchorId) {
  final finder = find.byKey(contentAnchorKey(anchorId), skipOffstage: false);
  if (finder.evaluate().isEmpty) return null;
  return tester.getRect(finder);
}

/// The part of the scroll viewport the reader can actually see and tap.
Rect _visibleViewport(WidgetTester tester, String scrollKey) {
  final rect = tester.getRect(find.byKey(Key(scrollKey)));
  return Rect.fromLTRB(
    rect.left,
    rect.top + _visibleInset(tester),
    rect.right,
    rect.bottom,
  );
}

int? _shuqiIndexOf(String anchorId) {
  const prefix = 'directory/chapter:';
  if (!anchorId.startsWith(prefix)) return null;
  final id = anchorId.substring(prefix.length);
  return int.tryParse(id.replaceFirst('c', ''));
}

int? _authorIndexOf(String anchorId) {
  const prefix = 'works/work:';
  if (!anchorId.startsWith(prefix)) return null;
  final id = anchorId.substring(prefix.length);
  final index = _author.works.indexWhere((work) => work.id == id);
  return index < 0 ? null : index;
}

/// Position of one author work relative to the page viewport's top edge.
double? _workDy(WidgetTester tester, String id) {
  final f = find.byKey(ValueKey('author_work_$id'), skipOffstage: false);
  if (f.evaluate().isEmpty) return null;
  return _viewportDy(tester, f, 'author_scroll');
}

/// [target]'s top edge relative to the *visible* top edge of the scroll view
/// (below the floating archive header, below the classic AppBar).
double _viewportDy(WidgetTester tester, Finder target, String scrollKey) =>
    tester.getTopLeft(target).dy -
    tester.getTopLeft(find.byKey(Key(scrollKey))).dy -
    _visibleInset(tester);

double _offset(WidgetTester tester, String scrollKey) {
  final view = tester.widget<CustomScrollView>(find.byKey(Key(scrollKey)));
  final controller = view.controller;
  expect(controller, isNotNull, reason: '$scrollKey must own a controller');
  return controller!.offset;
}

int? _synopsisMaxLines(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const Key('detail_description_text')),
  );
  return text.maxLines;
}

/// The first chapter row whose top edge is inside the viewport.
({int index, double dy})? _topShuqiRow(WidgetTester tester) {
  ({int index, double dy})? best;
  for (var i = 0; i < 60; i++) {
    final finder = find.byKey(
      ValueKey('shuqi-chapter-$i'),
      skipOffstage: false,
    );
    if (finder.evaluate().isEmpty) continue;
    final dy = _viewportDy(tester, finder, 'shuqi-detail-scroll');
    // A row parked exactly at the edge can measure a few ulps above it.
    if (dy < -0.5) continue;
    if (best == null || dy < best.dy) best = (index: i, dy: dy);
  }
  return best;
}

/// Position of one 书旗 chapter row relative to the scroll viewport's top edge,
/// or null when the row is not built. The layout branches put a Material AppBar
/// above one viewport and a frosted header over the other, so only the
/// viewport-relative position is comparable.
double? _rowDy(WidgetTester tester, int index) {
  final finder = find.byKey(
    ValueKey('shuqi-chapter-$index'),
    skipOffstage: false,
  );
  if (finder.evaluate().isEmpty) return null;
  return _viewportDy(tester, finder, 'shuqi-detail-scroll');
}

/// The first work card/row whose top edge is inside the viewport.
({String id, double dy})? _topAuthorWork(WidgetTester tester) {
  ({String id, double dy})? best;
  for (final work in _author.works) {
    final finder = find.byKey(
      ValueKey('author_work_${work.id}'),
      skipOffstage: false,
    );
    if (finder.evaluate().isEmpty) continue;
    final dy = _viewportDy(tester, finder, 'author_scroll');
    if (dy < -0.5) continue;
    if (best == null || dy < best.dy) best = (id: work.id, dy: dy);
  }
  return best;
}

Widget _shuqiPage({List<String>? calls, int chapters = 40}) => ShuqiDetailPage(
  bookId: '34078',
  bookLoader: (_) async {
    calls?.add('book:34078');
    return _shuqiBook;
  },
  tocLoader: (_) async {
    calls?.add('toc:34078');
    return _shuqiToc(chapters);
  },
);

List<Chapter> _chapters(int count, {bool volumeNames = true}) => [
  for (var i = 0; i < count; i++)
    Chapter(
      itemId: 'chapter-${i + 1}',
      title: '第${i + 1}章 故事的另一种可能',
      volumeName: !volumeNames
          ? ''
          : i < count / 2
          ? '第一卷 · 初见'
          : '终卷 · 星河',
    ),
];

const _shuqiBook = {
  'data': {
    'bookId': '34078',
    'name': '凡人修仙传',
    'author': '忘语',
    'intro': '一个普通山村小子',
    'kind': '玄幻',
    'coverUrl': '',
    'wordCount': '2451万字',
    'status': '完结',
  },
};

Map<String, dynamic> _shuqiToc(int count) => {
  'data': {
    'path': 'h5',
    'total': count,
    'chapters': [
      for (var i = 0; i < count; i++)
        {'chapterId': 'c$i', 'title': '第 ${i + 1} 章 山边小村', 'isVip': false},
    ],
  },
};

final _book = MediaItem(
  id: 'book',
  title: '开局废弃宗门，我召唤了大帝长老',
  cover: '',
  author: '香瓜贼甜',
  badge: '玄幻脑洞',
  ep: '',
  kind: 'book',
);

AuthorProfile get _author => AuthorProfile(
  id: '1988336383174046',
  name: '七彩虹桥的吕师傅',
  description: '人生是旷野呀朋友！',
  level: '作家Lv.5',
  followerCount: 20905,
  workCount: 120,
  works: [
    for (var i = 0; i < 120; i++)
      AuthorWork(
        id: 'work-$i',
        title: '作品 ${i + 1} 号：一段很长很长的书名用来占位',
        abstract: '【轻松校园】',
        category: '都市脑洞',
        creationStatus: 1,
        wordNumber: 115815,
      ),
  ],
);

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? lastRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastRoute = route;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) lastRoute = newRoute;
  }
}
