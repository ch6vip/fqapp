import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_status_bar.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets(
    'default pagination supports taps, swipes and real chapter pages',
    (tester) async {
      await _size(tester, const Size(390, 760));
      final store = MemoryReaderStore();
      await tester.pumpWidget(_app(store: store));
      await tester.pumpAndSettle();
      final initial = _pager(tester);
      expect(initial.layout.pages.length, greaterThan(3));
      expect(initial.pageIndex, 0);
      expect(find.byKey(const ValueKey('reader-paragraph-list')), findsNothing);
      var status = tester.widget<ReaderStatusBar>(find.byType(ReaderStatusBar));
      expect(status.pageIndex, 0);
      expect(status.pageCount, initial.layout.pages.length);
      await _tapSide(tester, 1);
      expect(_pager(tester).pageIndex, 1);
      expect(store.entry?['textOffset'], initial.layout.pages[1].start);
      expect(store.entry?['positionVersion'], 2);
      expect(store.entry?['episode'], 0);
      await _swipe(tester, 1);
      expect(_pager(tester).pageIndex, 2);
      await _tapSide(tester, -1);
      expect(_pager(tester).pageIndex, 1);
      await _swipe(tester, -1);
      expect(_pager(tester).pageIndex, 0);
      status = tester.widget<ReaderStatusBar>(find.byType(ReaderStatusBar));
      expect(status.pageIndex, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('opening menus does not repaginate or move the current page', (
    tester,
  ) async {
    await _size(tester, const Size(390, 760));
    final store = MemoryReaderStore();
    await tester.pumpWidget(_app(store: store));
    await tester.pumpAndSettle();
    await _tapSide(tester, 1);
    final layout = _pager(tester).layout;
    final saved = store.entry?['textOffset'];
    final viewport = tester.getRect(_surface);
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(viewport.center);
      await tester.pump(const Duration(milliseconds: 80));
      expect(_pager(tester).layout, same(layout));
      expect(_pager(tester).pageIndex, 1);
      expect(tester.getRect(_surface), viewport);
      await tester.pumpAndSettle();
      expect(store.entry?['textOffset'], saved);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid taps cannot skip pages during an unfinished turn', (
    tester,
  ) async {
    await _size(tester, const Size(390, 760));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final rect = tester.getRect(_surface);
    final right = Offset(rect.left + rect.width * .9, rect.center.dy);
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(right);
    await tester.tapAt(right);
    await tester.pumpAndSettle();
    expect(_pager(tester).pageIndex, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'swiping across chapters enters the next first or previous last page',
    (tester) async {
      await _size(tester, const Size(390, 760));
      final store = MemoryReaderStore(
        entry: {
          'id': 'paged-book',
          'kind': 'book',
          'chapterId': 'chapter-1',
          'positionVersion': 1,
          'textOffset': 1000000,
        },
      );
      final cache = MemoryChapterCache();
      var requests = 0;
      await tester.pumpWidget(
        _app(
          store: store,
          cache: cache,
          loader: (chapter) async {
            requests++;
            return _text(chapter);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(_pager(tester).pageIndex, _pager(tester).layout.pages.length - 1);
      final loaded = requests;
      await _swipe(tester, 1);
      // The boundary page defers the chapter swap briefly so its 章末 buttons
      // stay tappable; give the fake clock that window.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(store.entry?['chapterId'], 'chapter-2');
      expect(_pager(tester).pageIndex, 0);
      await _swipe(tester, -1);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(store.entry?['chapterId'], 'chapter-1');
      expect(_pager(tester).pageIndex, _pager(tester).layout.pages.length - 1);
      expect(
        requests,
        lessThanOrEqualTo(loaded + 1),
      ); // Only the next prefetch.
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed previous chapter keeps history and retry still opens its end',
    (tester) async {
      await _size(tester, const Size(390, 760));
      final store = MemoryReaderStore();
      var failPrevious = true;
      await tester.pumpWidget(
        _app(
          store: store,
          startIndex: 1,
          loader: (chapter) async {
            if (chapter.itemId == 'chapter-1' && failPrevious) {
              throw StateError('上一章暂时不可用');
            }
            return _text(chapter);
          },
        ),
      );
      await tester.pumpAndSettle();
      final saved = Map<String, dynamic>.of(store.entry!);
      await _swipe(tester, -1);
      // Boundary landing defers the previous-chapter request; see the swipe
      // test above.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.textContaining('上一章暂时不可用'), findsOneWidget);
      expect(store.entry?['chapterId'], saved['chapterId']);
      expect(store.entry?['textOffset'], saved['textOffset']);
      failPrevious = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(store.entry?['chapterId'], 'chapter-1');
      expect(_pager(tester).pageIndex, _pager(tester).layout.pages.length - 1);
      expect(_pager(tester).pageIndex, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'orientation and repeated font changes retain the same text anchor',
    (tester) async {
      await _size(tester, const Size(390, 760));
      final store = MemoryReaderStore();
      await tester.pumpWidget(_app(store: store));
      await tester.pumpAndSettle();
      await _tapSide(tester, 1);
      await _tapSide(tester, 1);
      final anchor = store.entry!['textOffset'] as int;
      final oldCount = _pager(tester).layout.pages.length;
      await tester.binding.setSurfaceSize(const Size(760, 390));
      await tester.pumpAndSettle();
      _expectAnchor(tester, store, anchor);
      await _openAppearance(tester);
      for (var i = 0; i < 4; i++) {
        await tester.ensureVisible(find.byTooltip('增大字号'));
        await tester.tap(find.byTooltip('增大字号'));
        await tester.pumpAndSettle();
        _expectAnchor(tester, store, anchor);
      }
      await tester.tap(find.byTooltip('关闭排版设置'));
      await tester.pumpAndSettle();
      expect(_pager(tester).layout.pages.length, isNot(oldCount));
      await tester.binding.setSurfaceSize(const Size(390, 760));
      await tester.pumpAndSettle();
      _expectAnchor(tester, store, anchor);
      expect((await ReaderPreferences.load()).fontSize, 22);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'switching between scrolling and pagination preserves text and choice',
    (tester) async {
      await _size(tester, const Size(390, 760));
      final store = MemoryReaderStore();
      await tester.pumpWidget(_app(store: store));
      await tester.pumpAndSettle();
      await _tapSide(tester, 1);
      await _tapSide(tester, 1);
      final anchor = store.entry!['textOffset'] as int;
      await _openAppearance(tester);
      await tester.tap(find.byKey(const ValueKey('reader-mode-scroll')));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPagedView), findsNothing);
      expect(store.entry?['textOffset'], anchor);
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('reader-paragraph-list')))
          .controller!;
      expect(scroll.offset, greaterThan(0));
      await tester.tap(find.byTooltip('关闭排版设置'));
      await tester.pumpAndSettle();
      expect((await ReaderPreferences.load()).pageMode, ReaderPageMode.scroll);
      await tester.drag(_surface, const Offset(0, -280));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      final newAnchor = store.entry!['textOffset'] as int;
      expect(newAnchor, greaterThan(anchor));
      await _openAppearance(tester);
      await tester.tap(find.byKey(const ValueKey('reader-mode-paged')));
      await tester.pumpAndSettle();
      _expectAnchor(tester, store, newAnchor);
      await tester.tap(find.byTooltip('关闭排版设置'));
      await tester.pumpAndSettle();
      expect((await ReaderPreferences.load()).pageMode, ReaderPageMode.paged);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('reopening waits for pending page saves before restoring text', (
    tester,
  ) async {
    await _size(tester, const Size(390, 760));
    final store = _DelayedStore();
    final cache = MemoryChapterCache();
    await tester.pumpWidget(_app(store: store, cache: cache));
    await tester.pumpAndSettle();
    final delayed = Completer<void>();
    store.delay = delayed.future;
    await _tapSide(tester, 1);
    final wanted = _pager(tester).layout.pages[1].start;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.idle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(find.byType(ReaderPage), findsNothing);
    await tester.binding.setSurfaceSize(const Size(760, 390));
    await tester.pumpWidget(_app(store: store, cache: cache));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    delayed.complete();
    store.delay = null;
    await tester.pumpAndSettle();
    _expectAnchor(tester, store, wanted);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'old pixel history migrates when first opened in pagination mode',
    (tester) async {
      await _size(tester, const Size(390, 760));
      final store = MemoryReaderStore(
        entry: {
          'id': 'paged-book',
          'chapterId': 'chapter-1',
          'episode': 0,
          'position': 500.0,
          'maxScroll': 1000.0,
        },
      );
      await tester.pumpWidget(_app(store: store));
      await tester.pumpAndSettle();
      expect(_pager(tester).pageIndex, greaterThan(0));
      expect(store.entry?['positionVersion'], 2);
      expect(store.entry?['textOffset'], greaterThan(0));
      final anchor = store.entry!['textOffset'] as int;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_app(store: store));
      await tester.pumpAndSettle();
      _expectAnchor(tester, store, anchor);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'book edges stay readable and chapter directory opens the first page',
    (tester) async {
      await _size(tester, const Size(390, 760));
      final store = MemoryReaderStore();
      await tester.pumpWidget(_app(store: store));
      await tester.pumpAndSettle();
      await _tapSide(tester, -1);
      expect(find.text('已是第一页'), findsOneWidget);
      expect(_pager(tester).pageIndex, 0);
      await tester.tapAt(tester.getRect(_surface).center);
      await tester.pumpAndSettle();
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(ListTile), matching: find.text('尾声')),
      );
      await tester.pumpAndSettle();
      expect(store.entry?['chapterId'], 'chapter-3');
      expect(_pager(tester).pageIndex, 0);
      expect(_pager(tester).layout.pages.length, 1);
      await _swipe(tester, 1);
      expect(find.text('本章完').hitTestable(), findsOneWidget);
      expect(find.text('已是最后一章'), findsNothing);
      expect(store.entry?['chapterId'], 'chapter-3');
      expect(_pager(tester).pageIndex, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scenario in [
    (size: const Size(280, 600), scale: 2.0),
    (size: const Size(780, 360), scale: 1.4),
  ]) {
    testWidgets(
      'paged reader fits ${scenario.size} at ${scenario.scale} scale',
      (tester) async {
        await _size(tester, scenario.size);
        await tester.pumpWidget(_app(scale: scenario.scale));
        await tester.pumpAndSettle();
        expect(_pager(tester).layout.pages.length, greaterThan(1));
        await _tapSide(tester, 1);
        expect(_pager(tester).pageIndex, 1);
        await _openAppearance(tester);
        expect(find.text('阅读方式'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭排版设置'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'pagination previews show full lines and the mode selector',
    (tester) async {
      final oldShadows = debugDisableShadows;
      try {
        await _size(tester, const Size(390, 844));
        await _loadPreviewFont(tester);
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();
        await _capture(tester, 'paged-reading');
        await _tapSide(tester, 1);
        await _capture(tester, 'paged-second');
        await _openAppearance(tester);
        expect(find.text('阅读方式'), findsOneWidget);
        await _capture(tester, 'mode-choice');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDisableShadows = oldShadows;
      }
    },
    skip: _previewFont.isEmpty,
  );
}

final _surface = find.byKey(const ValueKey('reader-page-surface'));
final _chapters = [
  Chapter(itemId: 'chapter-1', title: '第一章 山间来信', volumeName: '正文'),
  Chapter(itemId: 'chapter-2', title: '第二章 远山', volumeName: '正文'),
  Chapter(itemId: 'chapter-3', title: '尾声', volumeName: '正文'),
];
const _paragraphs = [
  '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗，看见远处的云正慢慢越过山脊。',
  '桌上放着一封尚未拆开的信，纸张微微泛黄，封口处印着一个熟悉的名字。他在窗前坐下，将信小心地展开。',
  '“如果有一天，你再次走到这条路的尽头，请记得停下来，听一听风的声音。”',
  '窗外传来鸟鸣，清亮又遥远。那些被时光掩藏的往事，仿佛随着这句话，重新有了颜色。',
  '他把信收进口袋，带上那本翻过许多遍的旧书。山路就在门外，阳光落在石阶上，一直延伸向远方。',
];

String _text(Chapter chapter) => chapter.itemId == 'chapter-3'
    ? '故事在这里告一段落。'
    : List.generate(
        24,
        (index) => _paragraphs[index % _paragraphs.length],
      ).join('\n');

Widget _app({
  MemoryReaderStore? store,
  ChapterCache? cache,
  ChapterTextLoader? loader,
  int startIndex = 0,
  double scale = 1,
}) => MaterialApp(
  builder: (context, child) => RepaintBoundary(
    key: const ValueKey('pagination-preview'),
    child: MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
  ),
  home: ReaderPage(
    bookId: 'paged-book',
    title: '山川来信',
    chapters: _chapters,
    startIndex: startIndex,
    readerStore: store ?? MemoryReaderStore(),
    chapterCache: cache ?? MemoryChapterCache(),
    chapterLoader: loader ?? (chapter) async => _text(chapter),
    readerDevice: _Device(),
  ),
);

ReaderPagedView _pager(WidgetTester tester) =>
    tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));

Future<void> _size(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _tapSide(WidgetTester tester, int direction) async {
  final rect = tester.getRect(_surface);
  await tester.tapAt(
    Offset(rect.left + rect.width * (direction > 0 ? .9 : .1), rect.center.dy),
  );
  await tester.pumpAndSettle();
}

Future<void> _swipe(WidgetTester tester, int direction) async {
  await tester.drag(
    _surface,
    Offset(-direction * tester.getRect(_surface).width * .8, 0),
  );
  await tester.pumpAndSettle();
}

Future<void> _openAppearance(WidgetTester tester) async {
  await tester.tapAt(tester.getRect(_surface).center);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('排版'));
  await tester.tap(find.text('排版'));
  await tester.pumpAndSettle();
}

void _expectAnchor(WidgetTester tester, MemoryReaderStore store, int anchor) {
  expect(store.entry?['textOffset'], anchor);
  final pager = _pager(tester);
  final page = pager.layout.pages[pager.pageIndex];
  expect(page.start, lessThanOrEqualTo(anchor));
  expect(page.end, greaterThanOrEqualTo(anchor));
}

class _DelayedStore extends MemoryReaderStore {
  Future<void>? delay;
  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
    await delay;
    await super.addHistory(value);
  }
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 9, 10, 21, 16),
    battery: 64,
    systemBrightness: .45,
  );
  @override
  Future<void> suspend() async {}
  @override
  Future<void> close() async {}
}

const _previewFont = String.fromEnvironment('READER_PREVIEW_FONT');

Future<void> _loadPreviewFont(WidgetTester tester) async {
  if (_previewFont.isEmpty) return;
  debugDisableShadows = false;
  await tester.runAsync(() async {
    final loader = FontLoader('Roboto')
      ..addFont(
        Future.value(
          ByteData.sublistView(await File(_previewFont).readAsBytes()),
        ),
      );
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (_previewFont.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('pagination-preview')),
  );
  await tester.runAsync(() async {
    final picture = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        'build/validation/reader-pagination-20260910/$name.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      picture.dispose();
    }
  });
}
