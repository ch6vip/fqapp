import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/chapter_summary.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/widgets/detail/detail_chapter_row.dart';
import 'package:fqapp/widgets/home/home_design.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('long descriptions expand and collapse without losing text', (
    tester,
  ) async {
    await _pumpBook(tester);
    final toggle = find.byKey(const Key('detail_description_toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    Text description() =>
        tester.widget<Text>(find.byKey(const Key('detail_description_text')));
    expect(description().maxLines, 3);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(description().maxLines, isNull);
    expect(description().data, _description);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(description().maxLines, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the actual cover opens a zoomable viewer and closes', (
    tester,
  ) async {
    await _pumpBook(tester);
    await tester.tap(find.byKey(const Key('detail_cover_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail_cover_viewer')), findsOneWidget);
    await tester.tap(find.byTooltip('关闭封面'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail_cover_viewer')), findsNothing);
    expect(find.byKey(const Key('detail_read_button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reversed and searched chapters keep their original identity', (
    tester,
  ) async {
    final observer = _RouteObserver();
    await _pumpBook(tester, observer: observer);
    final context = tester.element(find.byType(DetailPage));
    await _openDirectory(tester);
    await tester.tap(find.byKey(const Key('detail_directory_sort')));
    await tester.pumpAndSettle();
    expect(
      find
          .byKey(const Key('detail_directory_chapter_chapter-146'))
          .hitTestable(),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('detail_directory_search')),
      '146',
    );
    await tester.pumpAndSettle();
    expect(find.text('找到 1 章'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('detail_directory_chapter_chapter-146')),
    );
    await tester.idle();
    final page = (observer.lastRoute! as MaterialPageRoute).builder(context);
    expect(page, isA<ReaderPage>());
    expect((page as ReaderPage).startIndex, 145);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('directory search supports volume names and an empty result', (
    tester,
  ) async {
    await _pumpBook(tester);
    await _openDirectory(tester);
    final search = find.byKey(const Key('detail_directory_search'));
    await tester.enterText(search, '不存在的章节');
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配章节'), findsOneWidget);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(find.text('全部章节'), findsOneWidget);
    await tester.enterText(search, '终卷');
    await tester.pumpAndSettle();
    expect(find.text('找到 73 章'), findsOneWidget);
    expect(find.text('终卷 · 星河'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening the catalog cancels a late resume navigation', (
    tester,
  ) async {
    final store = _PendingHistory();
    final observer = _RouteObserver();
    await _pumpBook(tester, store: store, observer: observer);
    final context = tester.element(find.byType(DetailPage));
    await tester.tap(find.byKey(const Key('detail_read_button')));
    await _openDirectory(tester);
    store.pending.complete({'kind': 'book', 'chapterId': 'chapter-146'});
    await tester.pumpAndSettle();
    expect(observer.pushes, 2);
    await tester.tap(
      find.byKey(const Key('detail_directory_chapter_chapter-2')),
    );
    await tester.idle();
    expect(observer.pushes, 3);
    final page = (observer.lastRoute! as MaterialPageRoute).builder(context);
    expect((page as ReaderPage).startIndex, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stored chapter identity supplies the visible continue action', (
    tester,
  ) async {
    await _pumpBook(
      tester,
      store: MemoryReaderStore(
        entry: {'kind': 'book', 'chapterId': 'chapter-23', 'episode': 0},
      ),
    );
    expect(find.text('继续阅读'), findsOneWidget);
    expect(find.text('上次读到：第23章 故事的另一种可能'), findsOneWidget);
    await _openDirectory(tester);
    await tester.enterText(
      find.byKey(const Key('detail_directory_search')),
      '23',
    );
    await tester.pumpAndSettle();
    final row = tester.widget<DetailChapterRow>(
      find.byKey(const Key('detail_directory_chapter_chapter-23')),
    );
    expect(row.current, isTrue);
    expect(row.chapter.title, '第23章 故事的另一种可能');
  });

  testWidgets(
    'a large catalog builds visible rows and can find its last entry',
    (tester) async {
      await _pumpBook(tester, chapterCount: 10000);
      await _openDirectory(tester);
      expect(find.byType(DetailChapterRow).evaluate().length, lessThan(30));
      await tester.enterText(
        find.byKey(const Key('detail_directory_search')),
        '10000',
      );
      await tester.pumpAndSettle();
      expect(find.text('找到 1 章'), findsOneWidget);
      expect(
        find.byKey(const Key('detail_directory_chapter_chapter-10000')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (width: 320.0, height: 640.0, scale: 1.0, dark: false),
    (width: 320.0, height: 640.0, scale: 2.0, dark: false),
    (width: 320.0, height: 640.0, scale: 3.0, dark: true),
    (width: 393.0, height: 852.0, scale: 1.0, dark: true),
    (width: 800.0, height: 1000.0, scale: 1.0, dark: false),
    (width: 740.0, height: 360.0, scale: 1.5, dark: false),
  ]) {
    testWidgets('detail and catalog fit $scenario', (tester) async {
      await _pumpBook(
        tester,
        size: Size(scenario.width, scenario.height),
        scale: scenario.scale,
        dark: scenario.dark,
        reducedMotion: true,
      );
      expect(tester.takeException(), isNull);
      final title = tester.widget<Text>(
        find.byKey(const Key('detail_book_title')),
      );
      expect(title.maxLines, isNull);
      expect(
        find.byKey(const Key('detail_read_button')).hitTestable(),
        findsOneWidget,
      );
      await _openDirectory(tester);
      expect(tester.takeException(), isNull);
      for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
        expect(icon.icon?.fontPackage, 'flutter_lucide');
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets('large text and an open keyboard leave the search usable', (
    tester,
  ) async {
    await _pumpBook(tester, size: const Size(320, 640), scale: 2);
    await _openDirectory(tester);
    final search = find.byKey(const Key('detail_directory_search'));
    await tester.tap(search);
    tester.view.viewInsets = FakeViewPadding(
      bottom: 280 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.enterText(search, '146');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('找到 1 章'), findsOneWidget);
  });

  testWidgets('audio content markers never reach the preview excerpt', (
    tester,
  ) async {
    await _pumpBook(
      tester,
      previewLoader: (ids) async => ChapterSummary.fromPayload({
        'code': 0,
        'data': {
          'summary_item_data': [
            {
              'item_id': 'chapter-1',
              'summary':
                  '{!-- PGC_VOICE:{"content":"","duration":"664.79",'
                  '"source_provider":"audiobook"}--}第一章的正文开头',
            },
            {'item_id': 'chapter-2', 'summary': '{!-- PGC_VOICE:{"content":""'},
          ],
        },
      }),
    );

    expect(
      find.byKey(const Key('detail_preview_excerpt_chapter-1')),
      findsOneWidget,
    );
    expect(find.textContaining('PGC_VOICE'), findsNothing);
    expect(find.textContaining('第一章的正文开头'), findsOneWidget);
    // A marker-only preview is dropped instead of shown as raw JSON.
    expect(
      find.byKey(const Key('detail_preview_excerpt_chapter-2')),
      findsNothing,
    );
  });
}

Future<void> _pumpBook(
  WidgetTester tester, {
  Size size = const Size(393, 852),
  double scale = 1,
  bool dark = false,
  bool reducedMotion = false,
  int chapterCount = 146,
  MemoryReaderStore? store,
  NavigatorObserver? observer,
  ChapterPreviewLoader? previewLoader,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [?observer],
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        colorSchemeSeed: HomePalette.accent,
        useMaterial3: true,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reducedMotion,
        ),
        child: child!,
      ),
      home: DetailPage(
        item: _book,
        readerStore: store ?? MemoryReaderStore(),
        previewLoader: previewLoader,
        detailLoader: (id, {String tab = '小说'}) async => {
          'data': {'abstract': _description},
        },
        directoryLoader: (id, {String tab = '小说'}) async => [
          List.generate(
            chapterCount,
            (index) => Chapter(
              itemId: 'chapter-${index + 1}',
              title: '第${index + 1}章 故事的另一种可能',
              volumeName: index < chapterCount ~/ 2 ? '第一卷 · 初见' : '终卷 · 星河',
            ),
          ),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDirectory(WidgetTester tester) async {
  // The catalog entry lives in the page body. On small viewports with a large
  // text scale the masthead fills the viewport, so the sliver is offstage and
  // must be looked up with skipOffstage disabled before scrolling to it.
  final button = find.byKey(
    const Key('detail_directory_button'),
    skipOffstage: false,
  );
  await tester.ensureVisible(button);
  // A single frame is enough to apply the jump; settling here would hang while
  // an unrelated pending action keeps its progress indicator spinning.
  await tester.pump();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

final _book = MediaItem(
  id: 'detail-design-book',
  title: '开局废弃宗门，我召唤了大帝长老',
  cover: '',
  author: '香瓜贼甜',
  badge: '玄幻脑洞',
  ep: '',
  kind: 'book',
);

const _description =
    '苏狂身穿玄幻世界，激活无敌宗门系统，开局就召唤出了大帝境强者！\n'
    '只要招收天才进宗，还能继续抽取各类强者！\n'
    '而且弟子的修为精进，也能百倍返还给苏狂！\n'
    '于是，一段关于宗门、成长与奇遇的故事，就这样开始。';

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? lastRoute;
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    lastRoute = route;
  }
}

class _PendingHistory extends MemoryReaderStore {
  final pending = Completer<Map<String, dynamic>?>();

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) => pending.future;
}
