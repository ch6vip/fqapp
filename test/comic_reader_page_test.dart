import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/comic_reader_page.dart';
import 'package:fqapp/services/comic_page_layout.dart';
import 'package:fqapp/services/library_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.Image portrait;
  late ui.Image landscape;

  setUpAll(() async {
    portrait = await createTestImage(width: 100, height: 200, cache: false);
    landscape = await createTestImage(width: 400, height: 40, cache: false);
  });
  tearDownAll(() {
    portrait.dispose();
    landscape.dispose();
  });
  setUp(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test('page positions survive independent image height and width changes', () {
    final original = ComicPageLayout([100, 200, 300]);
    expect(original.positionAtOffset(150), 1.25);
    expect(original.offsetForPosition(1.25), 150);
    final resized = ComicPageLayout([250, 400, 150]);
    expect(resized.offsetForPosition(1.25), 350);
    expect(resized.positionAtOffset(350), 1.25);
    expect(resized.positionAtOffset(800), 3);
    expect(resized.offsetForPosition(3), 800);
  });

  test('invalid saved positions cannot produce an invalid scroll offset', () {
    final layout = ComicPageLayout([100, 200]);
    expect(layout.offsetForPosition(double.nan), 0);
    expect(layout.offsetForPosition(-4), 0);
    expect(layout.offsetForPosition(200), 300);
    expect(layout.positionAtOffset(-1), 0);
    expect(ComicPageLayout([]).positionAtOffset(50), 0);
    expect(() => ComicPageLayout([double.infinity]), throwsArgumentError);
  });

  testWidgets('images are lazy and displayed progress has manga page units', (
    tester,
  ) async {
    final store = _ComicStore();
    final requested = <String>{};
    final providers = <String, ImageProvider<Object>>{};
    await tester.pumpWidget(
      _app(
        store: store,
        loader: (chapter) async => _images(chapter, count: 30),
        provider: (image) {
          requested.add(image.url);
          return providers.putIfAbsent(
            image.url,
            () => _TestImageProvider(Future.value(portrait)),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsOneWidget);
    expect(requested.length, lessThan(10));
    final record = store.records['manga:comic-test']!;
    expect(record['kind'], 'manga');
    expect(record['contentId'], 'comic-test');
    expect(record['positionUnit'], 'comic-page');
    expect(record['maxScroll'], 30.0);
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });

  testWidgets(
    'resuming a page waits for images and preserves its fractional position',
    (tester) async {
      final store = _ComicStore()
        ..records['manga:comic-test'] = _saved(position: 2.3);
      await tester.pumpWidget(
        _app(
          store: store,
          loader: (chapter) async => _images(chapter, dimensions: false),
          provider: _providerFor(portrait),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        store.records['manga:comic-test']!['position'],
        closeTo(2.3, .001),
      );
      expect(find.text('第 3 / 6 页'), findsOneWidget);
      final before = _scroll(tester).offset;
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpAndSettle();
      expect(_scroll(tester).offset, lessThan(before));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        store.records['manga:comic-test']!['position'],
        closeTo(2.3, .001),
      );
      expect(tester.takeException(), isNull);
      await _leave(tester);
    },
  );

  testWidgets('scrolling stores the current page and reopening restores it', (
    tester,
  ) async {
    final store = _ComicStore();
    final provider = _providerFor(portrait);
    await tester.pumpWidget(_app(store: store, provider: provider));
    await tester.pumpAndSettle();
    _scroll(
      tester,
    ).jumpTo(2400); // 800-wide pages are 1600 high: page 2, halfway.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    expect(store.records['manga:comic-test']!['position'], closeTo(1.5, .001));
    await _leave(tester);
    await tester.pumpWidget(_app(store: store, provider: provider));
    await tester.pumpAndSettle();
    expect(_scroll(tester).offset, closeTo(2400, 1));
    expect(find.text('第 2 / 6 页'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets(
    'a pending exit write completes before a reopened reader restores',
    (tester) async {
      final store = _ComicStore();
      final provider = _providerFor(portrait);
      await tester.pumpWidget(_app(store: store, provider: provider));
      await tester.pumpAndSettle();
      _scroll(tester).jumpTo(2200);
      await tester.pumpAndSettle();
      final delayed = Completer<void>();
      store.writeDelay = delayed.future;
      await _leave(tester);
      store.writeDelay = null;
      await tester.pumpWidget(_app(store: store, provider: provider));
      await tester.pump();
      expect(find.byKey(const ValueKey('comic-reader-pages')), findsNothing);
      delayed.complete();
      await tester.pumpAndSettle();
      expect(_scroll(tester).offset, closeTo(2200, 1));
      await _leave(tester);
    },
  );

  for (final state in [
    'pending chapter',
    'failed chapter',
    'pending image',
    'failed image',
  ]) {
    testWidgets('leaving a $state preserves the last displayed history', (
      tester,
    ) async {
      final saved = _saved(chapterId: 'chapter-2', position: 1.2);
      final store = _ComicStore()..records['manga:comic-test'] = Map.of(saved);
      final chapter = Completer<List<ComicImage>>();
      final image = Completer<ui.Image>();
      final pendingProvider = _TestImageProvider(image.future);
      await tester.pumpWidget(
        _app(
          store: store,
          loader: state.endsWith('chapter') ? (_) => chapter.future : null,
          provider: state.endsWith('image')
              ? (_) => pendingProvider
              : _providerFor(portrait),
        ),
      );
      await tester.pump();
      if (state == 'failed chapter') {
        chapter.completeError(StateError('chapter unavailable'));
      }
      if (state == 'failed image') {
        image.completeError(StateError('image unavailable'));
      }
      await tester.pump();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await _leave(tester);
      if (!chapter.isCompleted) chapter.complete(_images(_chapters.first));
      if (!image.isCompleted) image.complete(portrait);
      await tester.pumpAndSettle();
      expect(store.records['manga:comic-test'], saved);
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  }

  testWidgets('a failed next chapter retains the previous visible page', (
    tester,
  ) async {
    final store = _ComicStore();
    await tester.pumpWidget(
      _app(
        store: store,
        loader: (chapter) async {
          if (chapter.itemId == 'chapter-2') {
            throw StateError('chapter unavailable');
          }
          return _images(chapter);
        },
        provider: _providerFor(portrait),
      ),
    );
    await tester.pumpAndSettle();
    _scroll(tester).jumpTo(1800);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一章'));
    await tester.pumpAndSettle();
    expect(find.textContaining('chapter unavailable'), findsOneWidget);
    expect(store.records['manga:comic-test']!['chapterId'], 'chapter-1');
    expect(
      store.records['manga:comic-test']!['position'],
      closeTo(1.125, .001),
    );
    await _leave(tester);
    expect(store.records['manga:comic-test']!['chapterId'], 'chapter-1');
  });

  testWidgets('later chapter selection wins over an earlier pending request', (
    tester,
  ) async {
    final store = _ComicStore();
    final pending = Completer<List<ComicImage>>();
    await tester.pumpWidget(
      _app(
        store: store,
        loader: (chapter) => chapter.itemId == 'chapter-2'
            ? pending.future
            : Future.value(_images(chapter)),
        provider: _providerFor(portrait),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一章'));
    await tester.pump();
    await tester.tap(find.byTooltip('下一章'));
    await tester.pumpAndSettle();
    pending.complete(_images(_chapters[1]));
    await tester.pumpAndSettle();
    expect(find.text('第三章'), findsOneWidget);
    expect(store.records['manga:comic-test']!['chapterId'], 'chapter-3');
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });

  testWidgets('directory and previous chapter controls work', (tester) async {
    final store = _ComicStore();
    await tester.pumpWidget(
      _app(store: store, provider: _providerFor(portrait)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第三章'));
    await tester.pumpAndSettle();
    expect(find.text('第三章'), findsOneWidget);
    await tester.tap(find.byTooltip('上一章'));
    await tester.pumpAndSettle();
    expect(find.text('第二章'), findsOneWidget);
    expect(store.records['manga:comic-test']!['chapterId'], 'chapter-2');
    await _leave(tester);
  });

  testWidgets('a failed chapter can be retried', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        store: _ComicStore(),
        loader: (chapter) async {
          if (++attempts == 1) throw StateError('temporarily unavailable');
          return _images(chapter);
        },
        provider: _providerFor(portrait),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新加载本章'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byKey(const ValueKey('comic-reader-pages')), findsOneWidget);
    await _leave(tester);
  });

  testWidgets(
    'a short failed image is retryable on a narrow large-text screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(280, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var attempts = 0;
      await tester.pumpWidget(
        _app(
          store: _ComicStore(),
          scale: 2.3,
          loader: (_) async => const [
            ComicImage(
              url: 'https://images.test/wide.png',
              width: 400,
              height: 40,
            ),
          ],
          provider: (_) => _TestImageProvider(
            ++attempts == 1
                ? Future.error(StateError('image unavailable'))
                : Future.value(landscape),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 1 页加载失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('重试图片'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试图片'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('第 1 页加载失败'), findsNothing);
      expect(tester.takeException(), isNull);
      await _leave(tester);
    },
  );

  testWidgets('an image opens a viewer that responds to a pinch gesture', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(store: _ComicStore(), provider: _providerFor(portrait)),
    );
    await tester.pumpAndSettle();
    final imageTop = tester.getTopLeft(find.byType(Image).first);
    await tester.tapAt(imageTop + const Offset(80, 80));
    await tester.pumpAndSettle();
    final viewer = find.byKey(const ValueKey('comic-image-zoom'));
    expect(viewer, findsOneWidget);
    final center = tester.getCenter(viewer);
    final left = await tester.startGesture(
      center + const Offset(-30, 0),
      pointer: 1,
    );
    final right = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await tester.pump();
    await left.moveTo(center + const Offset(-90, 0));
    await right.moveTo(center + const Offset(90, 0));
    await tester.pump();
    final transforms = tester.widgetList<Transform>(
      find.descendant(of: viewer, matching: find.byType(Transform)),
    );
    expect(
      transforms.any(
        (transform) => transform.transform.getMaxScaleOnAxis() > 1,
      ),
      isTrue,
    );
    await left.up();
    await right.up();
    await tester.tap(find.byTooltip('关闭大图'));
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });

  testWidgets('empty chapters and out-of-range start indices are safe', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        store: _ComicStore(),
        chapters: const [],
        provider: _providerFor(portrait),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无可阅读章节'), findsOneWidget);
    await _leave(tester);
    await tester.pumpWidget(
      _app(
        store: _ComicStore(),
        startIndex: 99,
        provider: _providerFor(portrait),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第三章'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });

  testWidgets('storage failure leaves images and chapter navigation usable', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        store: _ComicStore()..failWrites = true,
        provider: _providerFor(portrait),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一章'));
    await tester.pumpAndSettle();
    expect(find.text('第二章'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-reader-pages')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });
}

final _chapters = [
  Chapter(itemId: 'chapter-1', title: '第一章', volumeName: ''),
  Chapter(itemId: 'chapter-2', title: '第二章', volumeName: ''),
  Chapter(itemId: 'chapter-3', title: '第三章', volumeName: ''),
];

List<ComicImage> _images(
  Chapter chapter, {
  int count = 6,
  bool dimensions = true,
}) => List.generate(
  count,
  (index) => ComicImage(
    url: 'https://images.test/${chapter.itemId}/$index.png',
    width: dimensions ? 100 : null,
    height: dimensions ? 200 : null,
  ),
);

Map<String, dynamic> _saved({
  String chapterId = 'chapter-1',
  double position = 0,
}) => {
  'id': 'manga:comic-test',
  'contentId': 'comic-test',
  'kind': 'manga',
  'chapterId': chapterId,
  'episode': chapterId == 'chapter-1' ? 0 : 1,
  'position': position,
  'maxScroll': 6.0,
  'positionUnit': 'comic-page',
  'progress': .25,
  'title': '漫画',
};

ComicImageProviderFactory _providerFor(ui.Image image) {
  final providers = <String, ImageProvider<Object>>{};
  return (comic) => providers.putIfAbsent(
    comic.url,
    () => _TestImageProvider(Future.value(image)),
  );
}

Widget _app({
  required ReaderStore store,
  required ComicImageProviderFactory provider,
  ComicChapterLoader? loader,
  List<Chapter>? chapters,
  int startIndex = 0,
  double scale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: ComicReaderPage(
    bookId: 'comic-test',
    title: '漫画',
    chapters: chapters ?? _chapters,
    startIndex: startIndex,
    readerStore: store,
    chapterLoader: loader ?? (chapter) async => _images(chapter),
    imageProviderFactory: provider,
  ),
);

ScrollController _scroll(WidgetTester tester) => tester
    .widget<ListView>(find.byKey(const ValueKey('comic-reader-pages')))
    .controller!;

Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  final Future<ui.Image> future;
  _TestImageProvider(this.future);

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _TestImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    future.then((image) => ImageInfo(image: image.clone())),
  );
}

class _ComicStore implements ReaderStore {
  final records = <String, Map<String, dynamic>>{};
  Future<void>? writeDelay;
  bool failWrites = false;

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async =>
      records[id] == null ? null : Map.of(records[id]!);

  @override
  Future<void> addHistory(Map<String, dynamic> entry) async {
    final copy = Map<String, dynamic>.from(entry);
    await writeDelay;
    if (failWrites) throw StateError('storage unavailable');
    records[copy['id'] as String] = copy;
  }

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {
    await writeDelay;
    if (failWrites) throw StateError('storage unavailable');
    if (records[id] case final entry?) {
      records[id] = {
        ...entry,
        'episode': episode,
        'progress': progress,
        'chapterId': ?chapterId,
        'position': ?position,
        'maxScroll': ?maxScroll,
      };
    }
  }

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {}
}
