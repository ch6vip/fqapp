import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/author_profile.dart';
import 'package:fqapp/pages/author_page.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/shuqi_detail_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/detail/detail_archive.dart';
import 'package:fqapp/widgets/home/home_back_button.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

/// Classic 书旗 detail and author home (PR #292 task D).
///
/// Both pages keep their current state and loaders; these tests drive the same
/// injected loaders as the 档案 tests and assert the classic presentation plus
/// the entries that must survive the shell swap: 书旗's read-only source, the
/// lazily built 400-chapter catalogue, the author retry and `openBookDetail`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory hiveDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    hiveDirectory = await Directory.systemTemp.createTemp('fqapp-classic-2-');
    Hive.init(hiveDirectory.path);
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDirectory.existsSync()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  group('classic 书旗 detail', () {
    testWidgets('uses the old header, intro and 目录 rows', (tester) async {
      final store = await _pumpShuqi(tester);
      addTearDown(store.dispose);

      expect(find.byKey(const Key('shuqi-detail-classic-page')), findsOneWidget);
      // The archive shell and its glass dock are gone.
      expect(find.byType(WenkuPage), findsNothing);
      expect(find.byType(DetailArchiveDock), findsNothing);
      expect(find.text('书籍详情'), findsNothing);
      // Old AppBar title carries the book name.
      expect(
        tester
            .widget<Text>(find.byKey(const Key('shuqi-detail-appbar-title')))
            .data,
        '凡人修仙传',
      );
      expect(find.text('忘语'), findsOneWidget);
      expect(find.textContaining('书旗小说'), findsOneWidget);
      expect(find.byKey(const Key('shuqi-intro')), findsOneWidget);
      expect(find.text('共 2 章'), findsOneWidget);
      expect(find.text('书旗'), findsOneWidget);
      expect(find.text('第1章 山边小村'), findsOneWidget);
      expect(find.byKey(const ValueKey('shuqi-chapter-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('shuqi-chapter-1')), findsOneWidget);
      // 章名为占位 hint still shows when the toc has no real titles.
      expect(find.text('（章名为占位）'), findsNothing);
    });

    testWidgets('a toc failure keeps the book and retries in place', (
      tester,
    ) async {
      var tocCalls = 0;
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester);
      await tester.pumpWidget(
        _host(
          store: store,
          home: ShuqiDetailPage(
            bookId: '34078',
            bookLoader: (_) async => _shuqiBook,
            tocLoader: (_) async {
              tocCalls++;
              if (tocCalls == 1) throw StateError('toc down');
              return _shuqiToc;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('忘语'), findsOneWidget);
      expect(find.byKey(const Key('shuqi-intro')), findsOneWidget);
      expect(find.text('目录未加载'), findsOneWidget);
      expect(find.text('加载失败，请稍后重试'), findsOneWidget);

      await tester.tap(find.byKey(const Key('shuqi-toc-retry')));
      await tester.pumpAndSettle();
      expect(tocCalls, 2);
      expect(find.text('加载失败，请稍后重试'), findsNothing);
      expect(find.text('共 2 章'), findsOneWidget);
      expect(find.byKey(const ValueKey('shuqi-chapter-1')), findsOneWidget);
    });

    testWidgets('a 400-chapter catalogue still builds lazily', (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester);
      await tester.pumpWidget(
        _host(
          store: store,
          home: ShuqiDetailPage(
            bookId: '34078',
            bookLoader: (_) async => _shuqiBook,
            tocLoader: (_) async => {
              'data': {
                'path': 'h5',
                'total': 400,
                'chapters': List.generate(
                  400,
                  (i) => {
                    'chapterId': 'c$i',
                    'title': '第 ${i + 1} 章',
                    'isVip': false,
                  },
                ),
              },
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('shuqi-chapter-0'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('shuqi-chapter-399'), skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('开始阅读 opens the read-only shuqi reader', (tester) async {
      final observer = _RouteObserver();
      final store = await _pumpShuqi(tester, observer: observer);
      addTearDown(store.dispose);

      await tester.tap(find.byKey(const Key('shuqi-read-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
      expect(reader.localOnly, isTrue);
      expect(reader.bookId, 'shuqi:34078');
      final readerStore = reader.readerStore;
      expect(
        readerStore,
        isNotNull,
        reason: 'the reader must not fall back to the global history store',
      );
      // 书旗 is read-only: progress/history writes are dropped.
      await readerStore!.addHistory({'id': 'shuqi:34078', 'kind': 'book'});
      await readerStore.updateProgress('shuqi:34078', 0, 0.5);
      expect(await readerStore.historyEntry('shuqi:34078'), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('renders on light and dark surfaces', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final store = await _pumpShuqi(tester, brightness: brightness);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('shuqi-detail-classic-page')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      }
    });

    testWidgets('a long title and a 320dp screen do not overflow', (
      tester,
    ) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _size(tester, const Size(320, 560));
      await tester.pumpWidget(
        _host(
          store: store,
          home: ShuqiDetailPage(
            bookId: '34078',
            bookLoader: (_) async => {
              'data': {
                ...(_shuqiBook['data'] as Map<String, dynamic>),
                'name': '凡人修仙传之一个很长很长的书名用来测试窄屏头栏不溢出',
              },
            },
            tocLoader: (_) async => _shuqiToc,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final title = tester.widget<Text>(
        find.byKey(const Key('shuqi-detail-appbar-title')),
      );
      expect(title.overflow, TextOverflow.ellipsis);
      expect(find.byKey(const Key('shuqi-read-button')), findsOneWidget);
      expect(find.byKey(const Key('shuqi-book-title')), findsOneWidget);
    });

    testWidgets('switching to 档案 keeps the loaded book and toc', (
      tester,
    ) async {
      final calls = <String>[];
      final store = await _pumpShuqi(tester, calls: calls);
      addTearDown(store.dispose);
      expect(calls, ['book:34078', 'toc:34078']);

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      // Same State: no reload when the shell changes.
      expect(calls, ['book:34078', 'toc:34078']);
      expect(find.byType(WenkuPage), findsOneWidget);
      expect(find.text('书籍详情'), findsOneWidget);
      expect(find.byType(DetailArchiveDock), findsOneWidget);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(calls, ['book:34078', 'toc:34078']);
      expect(find.byKey(const Key('shuqi-detail-classic-page')), findsOneWidget);
    });
  });

  group('classic author home', () {
    testWidgets('uses the old header and the works grid', (tester) async {
      final store = await _pumpAuthor(tester);
      addTearDown(store.dispose);

      expect(find.byKey(const Key('author-classic-page')), findsOneWidget);
      expect(find.byType(ArchiveFeaturePage), findsNothing);
      expect(find.byType(HomeBackButton), findsOneWidget);
      expect(find.text('作者作品'), findsNothing);
      expect(find.text('作者'), findsOneWidget);
      expect(find.byKey(const Key('author_name')), findsOneWidget);
      expect(find.text('作家Lv.5'), findsOneWidget);
      expect(find.text('2.1万粉丝 · 5 部作品'), findsOneWidget);
      expect(find.byKey(const Key('author_description')), findsOneWidget);
      expect(find.text('全部作品'), findsOneWidget);
      // Works are the home cards, not the archive rows.
      expect(find.byType(HomeMediaCard), findsNWidgets(2));
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(
        find.byKey(const ValueKey('author_work_7676082357077543960')),
        findsOneWidget,
      );
      // No decorative archive file codes in classic.
      expect(
        find.text(detailArchiveFileCode('7676082357077543960')),
        findsNothing,
      );
      // word_number still reaches the card subtitle.
      expect(find.textContaining('11.6万字'), findsOneWidget);
    });

    testWidgets('a failure offers a retry that reloads', (tester) async {
      var attempts = 0;
      final store = await _pumpAuthor(
        tester,
        loader: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return _author;
        },
      );
      addTearDown(store.dispose);

      expect(find.byKey(const Key('author_retry')), findsOneWidget);
      expect(find.text('作家Lv.5'), findsNothing);
      await tester.tap(find.byKey(const Key('author_retry')));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('作家Lv.5'), findsOneWidget);
      expect(find.byType(HomeMediaCard), findsNWidgets(2));
    });

    testWidgets('an empty profile keeps the header and reports no works', (
      tester,
    ) async {
      final store = await _pumpAuthor(
        tester,
        loader: (_) async =>
            const AuthorProfile(id: '1', name: '无作品作者', followerCount: 12),
      );
      addTearDown(store.dispose);

      expect(find.text('无作品作者'), findsOneWidget);
      expect(find.byKey(const Key('author_empty')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a work opens the shared book detail route', (tester) async {
      final observer = _RouteObserver();
      final store = await _pumpAuthor(tester, observer: observer);
      addTearDown(store.dispose);
      final context = tester.element(find.byType(AuthorPage));

      await tester.tap(
        find.byKey(const ValueKey('author_work_7676082357077543960')),
      );
      await tester.idle();
      await tester.pump();
      final route = observer.lastRoute;
      expect(route, isA<MaterialPageRoute>());
      final pushed = (route! as MaterialPageRoute).builder(context);
      expect(pushed, isA<DetailPage>());
      expect(
        (pushed as DetailPage).item.id,
        '7676082357077543960',
        reason: 'the work must go through openBookDetail with its own id',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('renders on light, dark and a narrow screen', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final store = await _pumpAuthor(tester, brightness: brightness);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('author-classic-page')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      }
      final store = await _pumpAuthor(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      expect(find.byType(HomeMediaCard), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
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

Future<void> _size(
  WidgetTester tester, [
  Size size = const Size(393, 852),
]) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
}

Future<AppThemeStyleStore> _pumpShuqi(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  _RouteObserver? observer,
  List<String>? calls,
}) async {
  final store = AppThemeStyleStore();
  await store.select(AppThemeStyle.classic);
  await _size(tester);
  await tester.pumpWidget(
    _host(
      store: store,
      brightness: brightness,
      observers: observer == null ? const [] : [observer],
      home: ShuqiDetailPage(
        bookId: '34078',
        bookLoader: (_) async {
          calls?.add('book:34078');
          return _shuqiBook;
        },
        tocLoader: (_) async {
          calls?.add('toc:34078');
          return _shuqiToc;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

Future<AppThemeStyleStore> _pumpAuthor(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 800),
  _RouteObserver? observer,
  AuthorLoader? loader,
}) async {
  final store = AppThemeStyleStore();
  await store.select(AppThemeStyle.classic);
  await _size(tester, size);
  await tester.pumpWidget(
    _host(
      store: store,
      brightness: brightness,
      observers: observer == null ? const [] : [observer],
      home: AuthorPage(
        authorId: _author.id,
        fallbackName: _author.name,
        loader: loader ?? (_) async => _author,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

const _shuqiBook = {
  'data': {
    'bookId': '34078',
    'name': '凡人修仙传',
    'author': '忘语',
    'intro': '一个普通山村小子',
    'kind': '玄幻',
    'coverUrl': '',
    'wordCount': '2451万字',
    'lastChapter': '第2451章',
    'status': '完结',
    'chapterTotalNum': 2451,
  },
};

const _shuqiToc = {
  'data': {
    'path': 'h5',
    'total': 2,
    'chapters': [
      {'chapterId': '2180322', 'title': '第1章 山边小村', 'isVip': false},
      {'chapterId': '2180323', 'title': '第2章 山边小村', 'isVip': true},
    ],
  },
};

const _author = AuthorProfile(
  id: '1988336383174046',
  name: '七彩虹桥的吕师傅',
  description: '人生是旷野呀朋友！',
  level: '作家Lv.5',
  followerCount: 20905,
  workCount: 5,
  works: [
    AuthorWork(
      id: '7676082357077543960',
      title: '发现青梅真香且喜欢我，我重生了',
      abstract: '【轻松校园】',
      category: '都市脑洞',
      creationStatus: 1,
      wordNumber: 115815,
    ),
    AuthorWork(
      id: '7491705400958405694',
      title: '霸凌？穿书黄毛！学霸也是霸！',
      category: '都市脑洞',
      creationStatus: 0,
      wordNumber: 1328318,
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
