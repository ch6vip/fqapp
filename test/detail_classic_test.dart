import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/detail/classic_detail_read_bar.dart';
import 'package:fqapp/widgets/detail/detail_chapter_row.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/detail/detail_archive.dart';
import 'package:fqapp/widgets/detail/detail_hero.dart';
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
      final row = find.byKey(const ValueKey('detail_directory_chapter_chapter-1'));
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
            comments: [
              BookComment(id: 'c1', text: '很好看的一本书', userName: '读者甲'),
            ],
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

    testWidgets('入架 writes through the shared ShelfStore', (tester) async {
      final store = await _pumpClassic(tester);
      addTearDown(store.dispose);

      final pill = find.byKey(const Key('detail_shelf_button'));
      expect(pill, findsOneWidget);
      expect(find.text('＋ 书架'), findsOneWidget);
      // The Hive write only completes in a real-I/O zone; invoke the same
      // callback the pill would run on tap and let the box settle.
      await tester.runAsync(() async {
        tester.widget<HomePressable>(pill).onTap();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('✓ 书架'), findsOneWidget);
      expect(ShelfStore.instance.containsItem(_book), isTrue);
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
        expect(find.byKey(const Key('detail_preview_chapters')), findsOneWidget);
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
        item: _book.copyWith(
          title: '开局废弃宗门，我召唤了大帝长老，然后在诸天万界开了一家书店',
        ),
      );
      addTearDown(store.dispose);

      expect(tester.takeException(), isNull);
      // The AppBar title ellipsizes instead of pushing the entries off screen.
      final title = tester.widget<Text>(find.byKey(const Key('detail_page_title')));
      expect(title.overflow, TextOverflow.ellipsis);
      expect(find.byKey(const Key('detail_shelf_button')), findsOneWidget);
      expect(find.byKey(const Key('detail_read_button')).hitTestable(), findsOneWidget);
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
              ? {'id': book.id, 'kind': 'book', 'chapterId': 'chapter-23', 'episode': 22}
              : null,
        ),
        chapterCache: cache ?? MemoryChapterCache(),
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
              30,
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
