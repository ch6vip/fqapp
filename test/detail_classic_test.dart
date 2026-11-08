import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/ai_reading/settings/ai_book_settings_page.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/catalogue_order_preferences.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/detail/classic_detail_read_bar.dart';
import 'package:fqapp/widgets/detail/detail_chapter_row.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/detail/detail_archive.dart';
import 'package:fqapp/widgets/detail/detail_hero.dart';
import 'package:fqapp/widgets/detail/detail_reviews.dart';
import 'package:fqapp/widgets/home/home_shelf.dart';
import 'package:fqapp/widgets/detail/detail_states.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/fakes.dart';

/// Classic 详情 (PR #292 task D) against the one live `DetailPage`.
///
/// The page keeps a single `_DetailPageState`, so these tests drive the same
/// loaders, handlers and shelf/cache injections the 档案 tests use and only
/// assert that the classic layout reaches them: 续读 / 直读, 目录预览 and its
/// sheet, 评论, 入架, 下载, and the kind-specific primary label.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory hiveDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    hiveDirectory = await Directory.systemTemp.createTemp('fqapp-detail-');
    Hive.init(hiveDirectory.path);
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDirectory.existsSync()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  group('classic detail layout', () {
    testWidgets('novel shows hero, 简介, 目录预览 and the fixed read bar', (
      tester,
    ) async {
      final requests = <String>[];
      final store = await _pumpClassic(
        tester,
        requests: requests,
        withProgress: true,
      );
      addTearDown(store.dispose);

      expect(find.byKey(const Key('detail_classic_page')), findsOneWidget);
      // The archive shell and its glass dock are gone, not hidden behind it.
      expect(find.byType(WenkuPage), findsNothing);
      expect(find.byType(DetailArchiveDock), findsNothing);
      expect(find.byType(ClassicDetailReadBar), findsOneWidget);
      expect(find.byType(DetailHero), findsOneWidget);
      expect(find.byKey(const Key('detail_book_title')), findsOneWidget);

      // 简介 uses the old 15sp text header, not the archive code block.
      expect(find.text('简介'), findsOneWidget);
      expect(find.text('01 / SYNOPSIS'), findsNothing);
      expect(find.text('02 / CONTENTS'), findsNothing);

      // 目录预览: current ±1 only, with the reader's progress line and bar.
      expect(find.byKey(const Key('detail_preview_chapters')), findsOneWidget);
      final rows = tester.widgetList<DetailChapterRow>(
        find.byType(DetailChapterRow),
      );
      expect(rows.length, 3);
      expect(find.text('读到这里'), findsOneWidget);
      expect(find.byKey(const Key('detail_progress_line')), findsOneWidget);
      expect(find.byKey(const Key('detail_progress_bar')), findsOneWidget);
      expect(find.byKey(const Key('detail_progress_count')), findsOneWidget);
      // The inline catalogue belongs to the archive layout.
      expect(find.text('02 / CONTENTS'), findsNothing);
      expect(
        find.byKey(
          const ValueKey('detail-directory-entry-0'),
          skipOffstage: false,
        ),
        findsNothing,
      );

      // The ID row keeps its old place below the catalogue preview.
      expect(find.byKey(const Key('detail_id_row')), findsOneWidget);
      expect(requests, ['小说:book', '小说:book']);
    });

    testWidgets('the primary pill resumes the saved chapter', (tester) async {
      final observer = _RouteObserver();
      final store = await _pumpClassic(
        tester,
        observer: observer,
        withProgress: true,
      );
      addTearDown(store.dispose);

      expect(find.text('继续阅读 · 第23章'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail_read_button')));
      await tester.pump();
      final context = tester.element(find.byType(DetailPage));
      final page = (observer.lastRoute! as MaterialPageRoute).builder(context);
      expect(page, isA<ReaderPage>());
      // 番茄 catalogue index 22 is the 23rd chapter.
      expect((page as ReaderPage).startIndex, 22);
      // Inspect the navigation result before mounting the network-backed reader.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('全部 opens the searchable directory sheet', (tester) async {
      final observer = _RouteObserver();
      final store = await _pumpClassic(tester, observer: observer);
      addTearDown(store.dispose);

      final openAll = find.byKey(const Key('detail_directory_button'));
      expect(openAll, findsOneWidget);
      expect(find.textContaining('共30章 · 全部 ›'), findsOneWidget);
      await tester.tap(openAll);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_directory_search')), findsOneWidget);
      expect(find.byKey(const Key('detail_directory_scroll')), findsOneWidget);

      // A row in the sheet still runs the page's own `_openChapter`.
      final row = find.byKey(
        const ValueKey('detail_directory_chapter_chapter-1'),
      );
      expect(row, findsOneWidget);
      await tester.tap(row);
      // The reader shows a loading indicator while its chapter request runs, so
      // settling would wait on an animation that never ends.
      await tester.idle();
      await tester.pump();
      final page = observer.lastRoute;
      expect(page, isA<MaterialPageRoute>());
      final routed = (page! as MaterialPageRoute).builder(
        tester.element(find.byType(DetailPage)),
      );
      expect(routed, isA<ReaderPage>());
      expect((routed as ReaderPage).startIndex, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('下载 opens the same whole-book sheet', (tester) async {
      final store = await _pumpClassic(tester);
      addTearDown(store.dispose);

      await tester.tap(find.byKey(const Key('detail_action_下载')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_download_sheet')), findsOneWidget);
      expect(find.byKey(const Key('detail_download_all')), findsOneWidget);
      expect(find.byKey(const Key('detail_download_cached')), findsOneWidget);
    });

    testWidgets('a running batch shows determinate progress in the bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: ClassicDetailReadBar(
              label: '继续阅读 · 第23章',
              opening: false,
              onRead: () {},
              onListen: () {},
              onDownload: () {},
              download: (completed: 3, total: 12),
            ),
          ),
        ),
      );
      final progress = find.descendant(
        of: find.byKey(const Key('detail_action_下载')),
        matching: find.byType(CircularProgressIndicator),
      );
      expect(progress, findsOneWidget);
      // Determinate: a running batch must not keep an endless animation alive.
      expect(
        tester.widget<CircularProgressIndicator>(progress).value,
        closeTo(0.25, 1e-9),
      );
    });

    testWidgets('评论 stays reachable from the classic 书评 section', (
      tester,
    ) async {
      final store = await _pumpClassic(
        tester,
        extras: const DetailExtras(
          comments: BookCommentPage(
            comments: [BookComment(id: 'c1', text: '很好看的一本书', userName: '读者甲')],
            totalCount: 1,
          ),
        ),
      );
      addTearDown(store.dispose);

      expect(find.text('很好看的一本书'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail_reviews_more')));
      await tester.pumpAndSettle();
      expect(find.textContaining('全部书评'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a real tap on 入架 writes through the shared ShelfStore', (
      tester,
    ) async {
      final store = await _pumpClassic(tester);
      addTearDown(store.dispose);

      final pill = find.byKey(const Key('detail_shelf_button'));
      expect(pill, findsOneWidget);
      expect(find.text('＋ 书架'), findsOneWidget);
      // Tap the real hit target, then let the Hive write (real file I/O) land.
      await tester.runAsync(() async {
        await tester.tap(pill);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      expect(ShelfStore.instance.containsItem(_book), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('✓ 书架'), findsOneWidget);

      // Tapping again removes it.
      await tester.runAsync(() async {
        await tester.tap(pill);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      expect(ShelfStore.instance.containsItem(_book), isFalse);
    });

    testWidgets('目录 failure keeps the preview retryable', (tester) async {
      final store = await _pumpClassic(tester, directoryFails: true);
      addTearDown(store.dispose);

      expect(find.byKey(const Key('detail_inline_error')), findsOneWidget);
      expect(find.text('加载失败，请稍后重试'), findsOneWidget);
      // The read bar stays mounted but disabled instead of jumping away.
      final bar = tester.widget<ClassicDetailReadBar>(
        find.byType(ClassicDetailReadBar),
      );
      expect(bar.enabled, isFalse);
    });
  });

  group('classic detail kinds', () {
    for (final media in [
      (
        kind: 'book',
        label: '开始阅读',
        listen: true,
        download: true,
        action: '开始阅读',
      ),
      (
        kind: 'manga',
        label: '开始阅读',
        listen: false,
        download: false,
        action: '开始阅读',
      ),
      (
        kind: 'audio',
        label: '开始收听',
        listen: false,
        download: false,
        action: '开始收听',
      ),
      (
        kind: 'video',
        label: '开始观看',
        listen: false,
        download: false,
        action: '开始观看',
      ),
    ]) {
      testWidgets('${media.kind} keeps its own primary label and entries', (
        tester,
      ) async {
        final store = await _pumpClassic(tester, item: _item(media.kind));
        addTearDown(store.dispose);

        expect(find.text(media.label), findsOneWidget);
        expect(
          find.byKey(const Key('detail_action_听书')),
          media.listen ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('detail_action_下载')),
          media.download ? findsOneWidget : findsNothing,
        );
        // 漫画/听书/短剧 must not fake a 目录 preview progress bar.
        expect(
          find.byKey(const Key('detail_preview_chapters')),
          findsOneWidget,
        );
      });
    }
  });

  group('classic detail appearance', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('renders on ${brightness.name} surfaces', (tester) async {
        final store = await _pumpClassic(tester, brightness: brightness);
        addTearDown(store.dispose);

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('detail_classic_page')), findsOneWidget);
        expect(find.byKey(const Key('detail_read_button')), findsOneWidget);
        final bar = tester.widget<ClassicDetailReadBar>(
          find.byType(ClassicDetailReadBar),
        );
        expect(bar.enabled, isTrue);
      });
    }

    testWidgets('a long title and a 320dp screen do not overflow', (
      tester,
    ) async {
      final store = await _pumpClassic(
        tester,
        size: const Size(320, 560),
        item: _book.copyWith(title: '开局废弃宗门，我召唤了大帝长老，然后在诸天万界开了一家书店'),
      );
      addTearDown(store.dispose);

      expect(tester.takeException(), isNull);
      // The AppBar title ellipsizes instead of pushing the entries off screen.
      final title = tester.widget<Text>(
        find.byKey(const Key('detail_page_title')),
      );
      expect(title.overflow, TextOverflow.ellipsis);
      expect(find.byKey(const Key('detail_shelf_button')), findsOneWidget);
      expect(
        find.byKey(const Key('detail_read_button')).hitTestable(),
        findsOneWidget,
      );
    });
  });

  group('classic detail entries', () {
    testWidgets('书评 uses the old header and 全部 entry, no archive glass', (
      tester,
    ) async {
      final store = await _pumpClassic(
        tester,
        extras: const DetailExtras(
          comments: BookCommentPage(
            comments: [BookComment(id: 'c1', text: '很好看的一本书', userName: '读者甲')],
            totalCount: 1,
          ),
        ),
      );
      addTearDown(store.dispose);

      final header = find.byKey(const Key('detail_reviews_header'));
      expect(header, findsOneWidget);
      expect(tester.widget(header), isA<DetailSectionHeader>());
      expect(
        find.descendant(of: header, matching: find.byType(ArchiveSection)),
        findsNothing,
      );
      // No archive glass and no separate count subtitle in classic.
      expect(find.byType(GlassTextButton), findsNothing);
      expect(find.text('03 / REVIEWS'), findsNothing);
      final entry = find.byKey(const Key('detail_reviews_more'));
      expect(tester.widget(entry), isA<HomePressable>());
      expect(find.text('1 条 · 全部 ›'), findsOneWidget);

      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.textContaining('全部书评'), findsOneWidget);
      expect(find.text('很好看的一本书'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('档案 书评 keeps the archive header and glass entry', (
      tester,
    ) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.archive);
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          store: store,
          home: DetailPage(
            item: _book,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            extrasLoader: (_) async => const DetailExtras(
              comments: BookCommentPage(
                comments: [
                  BookComment(id: 'c1', text: '很好看的一本书', userName: '读者甲'),
                ],
                totalCount: 1,
              ),
            ),
            detailLoader: (id, {String tab = '小说'}) async => {
              'data': {'abstract': '一段故事。'},
            },
            directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final header = find.byKey(const Key('detail_reviews_header'));
      expect(
        find.descendant(of: header, matching: find.byType(ArchiveSection)),
        findsOneWidget,
      );
      expect(find.byType(GlassTextButton), findsWidgets);
      expect(find.text('03 / REVIEWS'), findsOneWidget);
    });

    testWidgets('the 目录 preview keeps the original order when 倒序 is saved', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        CatalogueOrderPreferences.key: true,
      });
      CatalogueOrderPreferences.instance.resetForTest();
      addTearDown(CatalogueOrderPreferences.instance.resetForTest);

      final store = await _pumpClassic(tester, chapters: 20);
      addTearDown(store.dispose);

      // The persisted order belongs to the 档案 inline catalogue; the classic
      // preview is always the reader's own slice in catalogue order.
      final rows = tester
          .widgetList<DetailChapterRow>(find.byType(DetailChapterRow))
          .toList();
      expect(rows.map((row) => row.chapter.itemId), [
        'chapter-1',
        'chapter-2',
        'chapter-3',
      ]);
      expect(find.byKey(const Key('detail-catalogue-order')), findsNothing);
    });

    testWidgets('the directory sheet sorts this visit and resets on reopen', (
      tester,
    ) async {
      final store = await _pumpClassic(tester, chapters: 20);
      addTearDown(store.dispose);

      Future<void> openSheet() async {
        await tester.tap(find.byKey(const Key('detail_directory_button')));
        await tester.pumpAndSettle();
      }

      await openSheet();
      expect(find.text('正序'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail_directory_sort')));
      await tester.pumpAndSettle();
      expect(find.text('倒序'), findsOneWidget);
      expect(
        find
            .byKey(const ValueKey('detail_directory_chapter_chapter-20'))
            .hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('detail_directory_close')));
      await tester.pumpAndSettle();

      // The sheet's order is per visit: reopening starts from 正序 again.
      await openSheet();
      expect(find.text('正序'), findsOneWidget);
      expect(find.text('倒序'), findsNothing);
      expect(
        find
            .byKey(const ValueKey('detail_directory_chapter_chapter-1'))
            .hitTestable(),
        findsOneWidget,
      );
    });

    testWidgets('经典书评标题与正文、条目共用同一条 gutter', (tester) async {
      final store = await _pumpClassic(
        tester,
        extras: const DetailExtras(
          comments: BookCommentPage(
            comments: [BookComment(id: 'c1', text: '很好看的一本书', userName: '读者甲')],
            totalCount: 1,
          ),
        ),
      );
      addTearDown(store.dispose);

      final titleX = tester.getTopLeft(find.text('书评')).dx;
      final bodyX = tester
          .getTopLeft(find.byKey(const Key('detail_description_text')))
          .dx;
      final rowX = tester
          .getTopLeft(find.byKey(const ValueKey('detail_review_c1')))
          .dx;
      // One gutter, exactly like 简介: the header must not stack its own 16dp
      // on top of the block's.
      expect(titleX, closeTo(homeGutter, 0.5));
      expect(titleX, closeTo(bodyX, 0.5));
      expect(rowX, closeTo(bodyX, 0.5));
    });

    testWidgets('经典书评 flush 场景同样只有一层 gutter', (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          store: store,
          home: Scaffold(
            body: DetailReviews(
              page: const BookCommentPage(
                comments: [
                  BookComment(id: 'c1', text: '很好看的一本书', userName: '读者甲'),
                ],
                totalCount: 1,
              ),
              bookId: 'book',
              flush: true,
              onOpenAll: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final titleX = tester.getTopLeft(find.text('书评')).dx;
      final rowX = tester
          .getTopLeft(find.byKey(const ValueKey('detail_review_c1')))
          .dx;
      expect(titleX, closeTo(0, 0.5));
      expect(rowX, closeTo(0, 0.5));
    });

    testWidgets('档案书评 flush 分支仍是零外层 gutter', (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.archive);
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          store: store,
          home: Scaffold(
            body: DetailReviews(
              page: const BookCommentPage(
                comments: [
                  BookComment(id: 'c1', text: '很好看的一本书', userName: '读者甲'),
                ],
                totalCount: 1,
              ),
              bookId: 'book',
              flush: true,
              onOpenAll: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('detail_reviews_header')),
          matching: find.byType(ArchiveSection),
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('书评')).dx,
        closeTo(
          tester.getTopLeft(find.byKey(const ValueKey('detail_review_c1'))).dx,
          0.5,
        ),
      );
    });

    testWidgets('整本下载 starts from the classic bar and shows progress', (
      tester,
    ) async {
      final cache = MemoryChapterCache();
      final fetched = <String>[];
      final store = await _pumpClassic(
        tester,
        cache: cache,
        chapters: 4,
        chapterLoader: (chapter) async {
          fetched.add(chapter.itemId);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return ChapterContent.fromPlainText(
            '正文${chapter.itemId}',
            illustrationsChecked: true,
          ).toCacheText();
        },
      );
      addTearDown(store.dispose);

      await tester.tap(find.byKey(const Key('detail_action_下载')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('detail_download_all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      // The bar itself carries the determinate progress of the running batch.
      final progress = find.descendant(
        of: find.byKey(const Key('detail_action_下载')),
        matching: find.byType(CircularProgressIndicator),
      );
      expect(progress, findsOneWidget);
      expect(
        tester.widget<CircularProgressIndicator>(progress).value,
        isNotNull,
      );

      await tester.pumpAndSettle();
      expect(fetched, ['chapter-1', 'chapter-2', 'chapter-3', 'chapter-4']);
      expect(await cache.cachedChapterIds('book'), {
        'chapter-1',
        'chapter-2',
        'chapter-3',
        'chapter-4',
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('听书 opens the audio page from the read bar', (tester) async {
      final observer = _RouteObserver();
      final store = await _pumpClassic(tester, observer: observer);
      addTearDown(store.dispose);
      final context = tester.element(find.byType(DetailPage));

      await tester.tap(find.byKey(const Key('detail_action_听书')));
      // Flush the pending open (audio history) without building the player,
      // whose retry timers would outlive the teardown.
      await tester.idle();
      final route = observer.lastRoute;
      expect(route, isA<MaterialPageRoute>());
      final page = (route! as MaterialPageRoute).builder(context);
      expect(page, isA<AudioPage>());
      expect((page as AudioPage).bookId, 'book');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('本书 AI opens the book settings page from the app bar', (
      tester,
    ) async {
      final observer = _RouteObserver();
      final store = await _pumpClassic(tester, observer: observer);
      addTearDown(store.dispose);
      final context = tester.element(find.byType(DetailPage));

      await tester.tap(find.byKey(const Key('detail_action_ai')));
      await tester.idle();
      final route = observer.lastRoute;
      expect(route, isA<MaterialPageRoute>());
      final page = (route! as MaterialPageRoute).builder(context);
      expect(page, isA<AiBookSettingsPage>());
      final settings = page as AiBookSettingsPage;
      expect(settings.bookId, 'book');
      expect(settings.chapters, hasLength(30));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('style scope', () {
    testWidgets('switching to 档案 keeps the page state and the loaded data', (
      tester,
    ) async {
      final requests = <String>[];
      final store = await _pumpClassic(tester, requests: requests);
      addTearDown(store.dispose);

      expect(find.byType(ClassicDetailReadBar), findsOneWidget);
      expect(requests, ['小说:book', '小说:book']);

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      // Same State: no second request, no second page element.
      expect(requests, ['小说:book', '小说:book']);
      expect(find.byType(WenkuPage), findsOneWidget);
      expect(find.byType(ClassicDetailReadBar), findsNothing);
      expect(find.byType(DetailArchiveDock), findsOneWidget);
      expect(find.text('02 / CONTENTS'), findsOneWidget);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(requests, ['小说:book', '小说:book']);
      expect(find.byType(ClassicDetailReadBar), findsOneWidget);
      expect(find.text('01 / SYNOPSIS'), findsNothing);
    });

    testWidgets('an archive scope stays on the ported layout', (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.archive);
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _host(
          store: store,
          home: DetailPage(
            item: _book,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            detailLoader: (id, {String tab = '小说'}) async => {},
            directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(WenkuPage), findsOneWidget);
      expect(find.byType(ClassicDetailReadBar), findsNothing);
      expect(find.text('02 / CONTENTS'), findsOneWidget);
      expect(find.byKey(const Key('detail_preview_chapters')), findsNothing);
      expect(find.byKey(const Key('detail_page_title')), findsOneWidget);
      final primary = tester.widget<GlassPillButton>(
        find.byKey(const Key('detail_read_button')),
      );
      expect(primary.onPressed, isNotNull);
    });
  });
}

Widget _host({
  required AppThemeStyleStore store,
  required Widget home,
  Brightness brightness = Brightness.light,
  List<NavigatorObserver> observers = const [],
}) => ValueListenableBuilder<AppThemeStyle>(
  valueListenable: store,
  builder: (context, style, _) => MaterialApp(
    navigatorObservers: observers,
    theme: AppTheme.createTheme(brightness, style: style),
    builder: (context, child) =>
        AppUiScope(store: store, child: child ?? const SizedBox.shrink()),
    home: home,
  ),
);

Future<AppThemeStyleStore> _pumpClassic(
  WidgetTester tester, {
  MediaItem? item,
  Size size = const Size(393, 852),
  Brightness brightness = Brightness.light,
  _RouteObserver? observer,
  List<String>? requests,
  bool withProgress = false,
  bool directoryFails = false,
  MemoryChapterCache? cache,
  DetailExtras? extras,
  Future<String> Function(Chapter chapter)? chapterLoader,
  int chapters = 30,
}) async {
  final store = AppThemeStyleStore();
  await store.select(AppThemeStyle.classic);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  final book = item ?? _book;
  await tester.pumpWidget(
    _host(
      store: store,
      brightness: brightness,
      observers: observer == null ? const [] : [observer],
      home: DetailPage(
        item: book,
        readerStore: MemoryReaderStore(
          entry: withProgress
              ? {
                  'id': book.id,
                  'kind': 'book',
                  'chapterId': 'chapter-23',
                  'episode': 22,
                }
              : null,
        ),
        chapterCache: cache ?? MemoryChapterCache(),
        chapterLoader: chapterLoader,
        extrasLoader: extras == null ? null : (_) async => extras,
        detailLoader: (id, {String tab = '小说'}) async {
          requests?.add('$tab:$id');
          return {
            'data': {'abstract': '一段关于宗门成长的故事。', 'creation_status': '1'},
          };
        },
        directoryLoader: (id, {String tab = '小说'}) async {
          requests?.add('$tab:$id');
          if (directoryFails) throw StateError('directory down');
          return [
            List.generate(
              chapters,
              (index) => Chapter(
                itemId: 'chapter-${index + 1}',
                title: '第${index + 1}章 故事的另一种可能',
                volumeName: '',
              ),
            ),
          ];
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

final _book = MediaItem(
  id: 'book',
  title: '开局废弃宗门，我召唤了大帝长老',
  cover: '',
  author: '香瓜贼甜',
  badge: '玄幻脑洞',
  ep: '',
  kind: 'book',
);

final _chapters = <Chapter>[
  Chapter(itemId: 'first', title: '第一章', volumeName: ''),
  Chapter(itemId: 'second', title: '第二章', volumeName: ''),
];

MediaItem _item(String kind) => MediaItem(
  id: 'book',
  title: '测试作品',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
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
