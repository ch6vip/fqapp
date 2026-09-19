import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/reader_illustration.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.Image portrait;
  setUpAll(() async {
    portrait = await createTestImage(width: 100, height: 150, cache: false);
  });
  tearDownAll(() => portrait.dispose());
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets(
    'batch illustration upgrade replaces prefetched text in the reader',
    (tester) async {
      await _size(tester);
      final cache = MemoryChapterCache();
      final content = _content();
      await _cache(
        cache,
        ChapterContent.fromPlainText(
          '第一章正文',
          illustrationsChecked: true,
        ).toCacheText(),
      );
      await cache.write(
        bookId: _bookId,
        chapterId: 'second',
        title: _nextChapter.title,
        text: content.legacyText,
      );
      final requests = <String>[];
      await tester.pumpWidget(
        _app(
          provider: _providerFor(portrait),
          cache: cache,
          chapters: [_chapter, _nextChapter],
          loader: (chapter) async {
            requests.add(chapter.itemId);
            return content.toCacheText();
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.text('缓存').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 1 章'));
      await tester.pumpAndSettle();
      expect(cache.content[_bookId]!['second'], content.toCacheText());
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.byTooltip('下一章'));
      await tester.pumpAndSettle();
      expect(
        _pager(tester).layout.blocks.where((block) => block.isImage),
        hasLength(2),
      );
      expect(requests, ['second']);
      expect(tester.takeException(), isNull);
      await _leave(tester);
    },
  );

  testWidgets(
    'preserved batch cache does not cancel an in-flight URL refresh',
    (tester) async {
      await _size(tester);
      final cache = MemoryChapterCache();
      final old = _content(firstUrl: 'https://images.test/first?x-expires=1');
      final fresh = _content(
        firstUrl: 'https://images.test/first?x-expires=9999999999',
      );
      await _cache(
        cache,
        ChapterContent.fromPlainText(
          '第一章正文',
          illustrationsChecked: true,
        ).toCacheText(),
      );
      await cache.write(
        bookId: _bookId,
        chapterId: 'second',
        title: _nextChapter.title,
        text: old.toCacheText(),
      );
      final pending = Completer<String>();
      var requests = 0;
      await tester.pumpWidget(
        _app(
          provider: _providerFor(portrait),
          cache: cache,
          chapters: [_chapter, _nextChapter],
          loader: (_) => ++requests == 1
              ? pending.future
              : Future.value(
                  ChapterContent.fromPlainText(old.legacyText).toCacheText(),
                ),
        ),
      );
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.byTooltip('下一章'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.byTooltip('上一章'));
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.text('缓存').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 1 章'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(find.textContaining('插图未更新'), findsOneWidget);
      pending.complete(fresh.toCacheText());
      await tester.pumpAndSettle();
      expect(cache.content[_bookId]!['second'], fresh.toCacheText());
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.byTooltip('下一章'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(
        _pager(tester).layout.blocks.where((block) => block.isImage),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await _leave(tester);
    },
  );

  for (final prefetchSource in ['disk', 'network', 'network-before-save']) {
    testWidgets('late $prefetchSource prefetch cannot undo a batch upgrade', (
      tester,
    ) async {
      await _size(tester);
      final delayedRead = Completer<String?>();
      final delayedFetch = Completer<String>();
      final delayedWrite = Completer<void>();
      final cache = switch (prefetchSource) {
        'disk' => _DelayedPrefetchCache(delayedRead.future),
        'network-before-save' => _DelayedWriteCache(delayedWrite.future),
        _ => MemoryChapterCache(),
      };
      await _cache(
        cache,
        ChapterContent.fromPlainText(
          '第一章正文',
          illustrationsChecked: true,
        ).toCacheText(),
      );
      final requests = <String>[];
      final content = _content();
      await tester.pumpWidget(
        _app(
          provider: _providerFor(portrait),
          cache: cache,
          chapters: [_chapter, _nextChapter],
          loader: (chapter) {
            requests.add(chapter.itemId);
            if (prefetchSource != 'disk' && requests.length == 1) {
              return delayedFetch.future;
            }
            return Future.value(content.toCacheText());
          },
        ),
      );
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.text('缓存').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 1 章'));
      await tester.pumpAndSettle();
      if (prefetchSource != 'network-before-save') {
        expect(cache.content[_bookId]!['second'], content.toCacheText());
      }
      if (prefetchSource == 'disk') {
        delayedRead.complete('迟到的旧缓存');
      } else {
        delayedFetch.complete(
          ChapterContent.fromPlainText('迟到的文字回退').toCacheText(),
        );
      }
      await tester.pumpAndSettle();
      if (cache is _DelayedWriteCache) {
        expect(
          cache.chapterWrites,
          1,
          reason: 'A stale prefetch must not queue a second disk write.',
        );
        delayedWrite.complete();
        await tester.pumpAndSettle();
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.byTooltip('下一章'));
      await tester.pumpAndSettle();
      expect(cache.content[_bookId]!['second'], content.toCacheText());
      expect(
        _pager(tester).layout.blocks.where((block) => block.isImage),
        hasLength(2),
      );
      expect(
        requests,
        prefetchSource == 'disk' ? ['second'] : ['second', 'second'],
      );
      expect(tester.takeException(), isNull);
      await _leave(tester);
    });
  }

  testWidgets(
    'cancelled batch does not suppress or overwrite a later reader refresh',
    (tester) async {
      await _size(tester);
      final cache = MemoryChapterCache();
      await _cache(
        cache,
        ChapterContent.fromPlainText(
          '第一章正文',
          illustrationsChecked: true,
        ).toCacheText(),
      );
      await cache.write(
        bookId: _bookId,
        chapterId: 'second',
        title: _nextChapter.title,
        text: '第二章旧正文',
      );
      final batch = Completer<String>();
      final refresh = Completer<String>();
      var requests = 0;
      await tester.pumpWidget(
        _app(
          provider: _providerFor(portrait),
          cache: cache,
          chapters: [_chapter, _nextChapter],
          loader: (_) => ++requests == 1 ? batch.future : refresh.future,
        ),
      );
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.text('缓存').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存后 1 章'));
      await tester.pump();
      await tester.tap(find.text('停止缓存'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.byTooltip('下一章'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      final content = _content();
      refresh.complete(content.toCacheText());
      await tester.pumpAndSettle();
      batch.complete(ChapterContent.fromPlainText('已取消的文字回退').toCacheText());
      await tester.pumpAndSettle();
      expect(cache.content[_bookId]!['second'], content.toCacheText());
      expect(
        _pager(tester).layout.blocks.where((block) => block.isImage),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await _leave(tester);
    },
  );

  testWidgets('late image decoding keeps the same page and layout', (
    tester,
  ) async {
    await _size(tester);
    final pending = Completer<ui.Image>();
    final provider = _TestImageProvider(pending.future);
    final store = MemoryReaderStore();
    await tester.pumpWidget(_app(provider: (_) => provider, store: store));
    await tester.pumpAndSettle();
    await _showImage(tester);
    final layout = _pager(tester).layout;
    final page = _pager(tester).pageIndex;
    final offset = store.entry!['textOffset'];
    final rect = tester.getRect(
      find.byType(ReaderIllustration).hitTestable().first,
    );
    expect(find.text('正在加载插图').hitTestable(), findsOneWidget);
    pending.complete(portrait);
    await tester.pumpAndSettle();
    expect(_pager(tester).layout, same(layout));
    expect(_pager(tester).pageIndex, page);
    expect(store.entry!['textOffset'], offset);
    expect(
      tester.getRect(find.byType(ReaderIllustration).hitTestable().first),
      rect,
    );
    final rendered = tester.widget<Image>(
      find.descendant(
        of: find.byType(ReaderIllustration).hitTestable().first,
        matching: find.byType(Image),
      ),
    );
    expect(rendered.fit, BoxFit.contain);
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });

  testWidgets('tapping an illustration opens zoom without turning or menus', (
    tester,
  ) async {
    await _size(tester);
    final store = MemoryReaderStore();
    await tester.pumpWidget(
      _app(provider: _providerFor(portrait), store: store),
    );
    await tester.pumpAndSettle();
    await _showImage(tester);
    final anchor = store.entry!['textOffset'];
    final page = _pager(tester).pageIndex;
    await tester.tap(find.byType(ReaderIllustration).hitTestable().first);
    await tester.pumpAndSettle();
    final viewer = find.byKey(const ValueKey('reader-illustration-viewer'));
    expect(viewer, findsOneWidget);
    expect(store.entry!['textOffset'], anchor);
    final center = tester.getCenter(viewer);
    final left = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 1,
    );
    final right = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await tester.pump();
    await left.moveTo(center - const Offset(100, 0));
    await right.moveTo(center + const Offset(100, 0));
    await tester.pump();
    final transforms = tester.widgetList<Transform>(
      find.descendant(of: viewer, matching: find.byType(Transform)),
    );
    expect(
      transforms.any((t) => t.transform.getMaxScaleOnAxis() > 1.2),
      isTrue,
    );
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭插图'));
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);
    expect(_pager(tester).pageIndex, page);
    expect(store.entry!['textOffset'], anchor);
    expect(find.byTooltip('收起阅读菜单').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });

  testWidgets('a picture stays selected through rotation and reading modes', (
    tester,
  ) async {
    await _size(tester);
    final store = MemoryReaderStore();
    await tester.pumpWidget(
      _app(provider: _providerFor(portrait), store: store),
    );
    await tester.pumpAndSettle();
    await _showImage(tester, index: 1);
    final anchor = store.entry!['textOffset'];
    await tester.binding.setSurfaceSize(const Size(760, 390));
    await tester.pumpAndSettle();
    expect(store.entry!['textOffset'], anchor);
    final pager = _pager(tester);
    expect(
      pager.layout.pages[pager.pageIndex].fragments.single.block.isImage,
      isTrue,
    );
    await _openMenu(tester);
    await _openSettings(tester);
    await tester.tap(find.text('排版'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('reader-mode-scroll')),
    );
    await tester.tap(find.byKey(const ValueKey('reader-mode-scroll')));
    await tester.pumpAndSettle();
    expect(store.entry!['textOffset'], anchor);
    expect(_scroll(tester).offset, greaterThan(0));
    await tester.ensureVisible(
      find.byKey(const ValueKey('reader-mode-paged')),
    );
    await tester.tap(find.byKey(const ValueKey('reader-mode-paged')));
    await tester.pumpAndSettle();
    expect(store.entry!['textOffset'], anchor);
    await tester.tap(find.byTooltip('关闭排版设置'));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(390, 760));
    await tester.pumpAndSettle();
    expect(store.entry!['textOffset'], anchor);
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });

  testWidgets(
    'failed image retry keeps its slot and does not open full screen',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 360,
              child: ReaderIllustration(
                image: _image,
                providerFactory: (_) => _TestImageProvider(
                  ++attempts == 1
                      ? Future<ui.Image>.error(StateError('image unavailable'))
                      : Future.value(portrait),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('插图加载失败'), findsOneWidget);
      final rect = tester.getRect(find.byType(ReaderIllustration));
      await tester.tap(find.text('重试插图'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('插图加载失败'), findsNothing);
      expect(
        find.byKey(const ValueKey('reader-illustration-viewer')),
        findsNothing,
      );
      expect(tester.getRect(find.byType(ReaderIllustration)), rect);
      expect(tester.takeException(), isNull);
      await _leave(tester);
    },
  );

  for (final mode in ['paged', 'scroll']) {
    testWidgets('image-only cached chapter opens offline in $mode mode', (
      tester,
    ) async {
      await _size(tester);
      SharedPreferences.setMockInitialValues({'reader_page_mode': mode});
      final cache = MemoryChapterCache();
      final onlyImage = ChapterContent(blocks: const [_image]);
      await _cache(cache, onlyImage.toCacheText());
      var requests = 0;
      await tester.pumpWidget(
        _app(
          provider: _providerFor(portrait),
          cache: cache,
          chapters: [Chapter(itemId: 'first', title: '', volumeName: '')],
          loader: (_) async {
            requests++;
            throw StateError('offline');
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(find.byType(ReaderIllustration).hitTestable(), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      if (mode == 'paged') {
        expect(_pager(tester).layout.pages, hasLength(1));
        expect(_pager(tester).layout.pages.single.fragments.single.top, 0);
        expect(find.byType(SingleChildScrollView), findsNothing);
      } else {
        final imageTop = tester.getTopLeft(find.byType(ReaderIllustration)).dy;
        final listTop = tester.getTopLeft(_scrollList).dy;
        final padding =
            tester.widget<ListView>(_scrollList).padding! as EdgeInsets;
        expect(imageTop - listTop, closeTo(padding.top, .001));
      }
      expect(tester.takeException(), isNull);
      await _leave(tester);
    });

    testWidgets(
      'legacy cache gains pictures without losing the $mode text anchor',
      (tester) async {
        await _size(tester);
        SharedPreferences.setMockInitialValues({'reader_page_mode': mode});
        final content = _content();
        final cache = MemoryChapterCache();
        await _cache(cache, content.legacyText);
        final oldOffset =
            '${_chapter.title}\n${content.legacyText}'.indexOf(_anchorText) + 4;
        final store = MemoryReaderStore(entry: _saved(oldOffset, version: 1));
        final pending = Completer<String>();
        await tester.pumpWidget(
          _app(
            provider: _providerFor(portrait),
            store: store,
            cache: cache,
            loader: (_) => pending.future,
          ),
        );
        await tester.pumpAndSettle();
        expect(store.entry!['textOffset'], oldOffset);
        expect(find.text('重试'), findsNothing);
        final oldScroll = mode == 'scroll' ? _scroll(tester).offset : 0;
        pending.complete(content.toCacheText());
        await tester.pumpAndSettle();
        final newOffset = _documentText(content).indexOf(_anchorText) + 4;
        expect(store.entry!['textOffset'], newOffset);
        expect(store.entry!['positionVersion'], 2);
        expect(
          ChapterContent.fromCacheText(
            cache.content[_bookId]!['first']!,
          ).images,
          hasLength(2),
        );
        if (mode == 'paged') {
          final pager = _pager(tester);
          expect(
            pager.layout.pages[pager.pageIndex].start,
            lessThanOrEqualTo(newOffset),
          );
          expect(
            pager.layout.pages[pager.pageIndex].end,
            greaterThanOrEqualTo(newOffset),
          );
        } else {
          expect(_scroll(tester).offset, greaterThan(oldScroll));
        }
        expect(tester.takeException(), isNull);
        await _leave(tester);
      },
    );
  }

  for (final version in [1, 2]) {
    testWidgets(
      'immediate cache upgrade preserves unrestored v$version history',
      (tester) async {
        await _size(tester);
        final content = _content();
        final cache = MemoryChapterCache();
        await _cache(cache, content.legacyText);
        final offset =
            '${_chapter.title}\n${content.legacyText}'.indexOf(_anchorText) + 4;
        final store = MemoryReaderStore(
          entry: _saved(offset, version: version),
        );
        await tester.pumpWidget(
          _app(
            provider: _providerFor(portrait),
            store: store,
            cache: cache,
            loader: (_) async => content.toCacheText(),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          store.entry!['textOffset'],
          _documentText(content).indexOf(_anchorText) + 4,
        );
        expect(_pager(tester).pageIndex, greaterThan(0));
        expect(tester.takeException(), isNull);
        await _leave(tester);
      },
    );
  }

  testWidgets('expired pictures survive text fallback and refresh on resume', (
    tester,
  ) async {
    await _size(tester);
    final old = _content(firstUrl: 'https://images.test/first?x-expires=1');
    final fresh = _content(
      firstUrl: 'https://images.test/first?x-expires=9999999999',
    );
    final cache = MemoryChapterCache();
    await _cache(cache, old.toCacheText());
    final imageOffset = _documentText(old).indexOf('\uFFFC');
    final store = MemoryReaderStore(entry: _saved(imageOffset));
    var requests = 0;
    await tester.pumpWidget(
      _app(
        provider: _providerFor(portrait),
        store: store,
        cache: cache,
        loader: (_) async => ++requests == 1
            ? ChapterContent.fromPlainText(old.legacyText).toCacheText()
            : fresh.toCacheText(),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(_pager(tester).layout.blocks.where((b) => b.isImage), hasLength(2));
    expect(cache.content[_bookId]!['first'], old.toCacheText());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(cache.content[_bookId]!['first'], fresh.toCacheText());
    expect(store.entry!['textOffset'], imageOffset);
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });

  testWidgets('late upgrade cannot return to the chapter already left', (
    tester,
  ) async {
    await _size(tester);
    final cache = MemoryChapterCache();
    await _cache(cache, _content().legacyText);
    final pending = Completer<String>();
    final store = MemoryReaderStore();
    await tester.pumpWidget(
      _app(
        provider: _providerFor(portrait),
        cache: cache,
        store: store,
        chapters: [_chapter, _nextChapter],
        loader: (chapter) => chapter.itemId == 'first'
            ? pending.future
            : Future.value('第二章独有正文。'),
      ),
    );
    await tester.pumpAndSettle();
    await _openMenu(tester);
    await _openSettings(tester);
    await tester.tap(find.byTooltip('下一章'));
    await tester.pumpAndSettle();
    expect(store.entry!['chapterId'], 'second');
    pending.complete(_content().toCacheText());
    await tester.pumpAndSettle();
    expect(store.entry!['chapterId'], 'second');
    expect(_pager(tester).layout.blocks.any((b) => b.isImage), isFalse);
    expect(tester.takeException(), isNull);
    await _leave(tester);
  });

  testWidgets(
    'returning during a pending upgrade still displays its pictures',
    (tester) async {
      await _size(tester);
      final cache = MemoryChapterCache();
      await _cache(cache, _content().legacyText);
      final pending = Completer<String>();
      final store = MemoryReaderStore();
      await tester.pumpWidget(
        _app(
          provider: _providerFor(portrait),
          cache: cache,
          store: store,
          chapters: [_chapter, _nextChapter],
          loader: (chapter) => chapter.itemId == 'first'
              ? pending.future
              : Future.value('第二章独有正文。'),
        ),
      );
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.byTooltip('下一章'));
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await _openSettings(tester);
      await tester.tap(find.byTooltip('上一章'));
      await tester.pumpAndSettle();
      expect(store.entry!['chapterId'], 'first');
      pending.complete(_content().toCacheText());
      await tester.pumpAndSettle();
      expect(
        _pager(tester).layout.blocks.where((b) => b.isImage),
        hasLength(2),
      );
      expect(store.entry!['chapterId'], 'first');
      expect(tester.takeException(), isNull);
      await _leave(tester);
    },
  );

  testWidgets('leaving and clearing cache cannot be undone by late images', (
    tester,
  ) async {
    await _size(tester);
    final cache = MemoryChapterCache();
    await _cache(cache, _content().legacyText);
    final pending = Completer<String>();
    await tester.pumpWidget(
      _app(
        provider: _providerFor(portrait),
        cache: cache,
        loader: (_) => pending.future,
      ),
    );
    await tester.pumpAndSettle();
    await _leave(tester);
    cache.content.clear();
    cache.catalogs.clear();
    pending.complete(_content().toCacheText());
    await tester.pumpAndSettle();
    expect(cache.content, isEmpty);
    expect(cache.catalogs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'truncated structured cache is replaced without displaying JSON',
    (tester) async {
      await _size(tester);
      final cache = MemoryChapterCache();
      await _cache(cache, _content().toCacheText().substring(0, 40));
      var requests = 0;
      await tester.pumpWidget(
        _app(
          provider: _providerFor(portrait),
          cache: cache,
          loader: (_) async {
            requests++;
            return _content().toCacheText();
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(
        _pager(tester).layout.blocks.where((b) => b.isImage),
        hasLength(2),
      );
      expect(find.textContaining('fqapp:chapter'), findsNothing);
      expect(tester.takeException(), isNull);
      await _leave(tester);
    },
  );
}

const _bookId = 'illustrated-book';
const _bookTitle = '插图测试书';
const _anchorText = '第 7 段之后仍停在这里';
const _image = ChapterImage(
  url: 'https://images.test/first',
  width: 1400,
  height: 2100,
);
final _chapter = Chapter(itemId: 'first', title: '第一章', volumeName: '正文');
final _nextChapter = Chapter(itemId: 'second', title: '第二章', volumeName: '正文');
final _scrollList = find.byKey(const ValueKey('reader-paragraph-list'));

ChapterContent _content({String firstUrl = 'https://images.test/first'}) =>
    ChapterContent(
      blocks: [
        const ChapterParagraph('图前正文。'),
        ChapterImage(url: firstUrl, width: 1400, height: 2100),
        const ChapterImage(
          url: 'https://images.test/second',
          width: 1400,
          height: 2103,
        ),
        for (var i = 0; i < 12; i++)
          ChapterParagraph(
            '第 $i 段之后仍停在这里。${List.filled(8, '清晨的风带来山间草木的清香。').join()}',
          ),
      ],
    );

String _documentText(ChapterContent content) => [
  _chapter.title,
  for (final block in content.blocks)
    block is ChapterParagraph ? block.text : '\uFFFC',
].join('\n');

Map<String, dynamic> _saved(int offset, {int version = 2}) => {
  'id': _bookId,
  'kind': 'book',
  'chapterId': 'first',
  'positionVersion': version,
  'textOffset': offset,
};

Future<void> _cache(MemoryChapterCache cache, String text) => cache.write(
  bookId: _bookId,
  chapterId: 'first',
  title: _chapter.title,
  text: text,
);

Widget _app({
  required ReaderImageProviderFactory provider,
  MemoryReaderStore? store,
  ChapterCache? cache,
  ChapterTextLoader? loader,
  List<Chapter>? chapters,
}) => MaterialApp(
  home: ReaderPage(
    bookId: _bookId,
    title: _bookTitle,
    chapters: chapters ?? [_chapter],
    startIndex: 0,
    readerStore: store ?? MemoryReaderStore(),
    chapterCache: cache ?? MemoryChapterCache(),
    chapterLoader: loader ?? (_) async => _content().toCacheText(),
    readerDevice: _Device(),
    imageProviderFactory: provider,
  ),
);

ReaderImageProviderFactory _providerFor(ui.Image image) {
  final providers = <String, ImageProvider<Object>>{};
  return (chapterImage) => providers.putIfAbsent(
    chapterImage.url,
    () => _TestImageProvider(Future.value(image)),
  );
}

ReaderPagedView _pager(WidgetTester tester) =>
    tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));
ScrollController _scroll(WidgetTester tester) =>
    tester.widget<ListView>(_scrollList).controller!;

Future<void> _showImage(WidgetTester tester, {int index = 0}) async {
  final pager = _pager(tester);
  final image = pager.layout.blocks.where((b) => b.isImage).elementAt(index);
  final page = pager.layout.pageForOffset(image.start);
  tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(page);
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester) async {
  if (find.byTooltip('收起阅读菜单').hitTestable().evaluate().isNotEmpty) return;
  await tester.tap(find.text(_bookTitle).hitTestable().first);
  await tester.pumpAndSettle();
}

Future<void> _size(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

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

class _DelayedPrefetchCache extends MemoryChapterCache {
  final Future<String?> pending;
  bool _delayed = false;
  _DelayedPrefetchCache(this.pending);

  @override
  Future<String?> read({required String bookId, required String chapterId}) {
    if (chapterId == 'second' && !_delayed) {
      _delayed = true;
      return pending;
    }
    return super.read(bookId: bookId, chapterId: chapterId);
  }
}

class _DelayedWriteCache extends MemoryChapterCache {
  final Future<void> pending;
  int chapterWrites = 0;
  _DelayedWriteCache(this.pending);

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
  }) async {
    if (chapterId == 'second') {
      chapterWrites++;
      await pending;
    }
    await super.write(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
    );
  }
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(time: DateTime(2026, 9, 10, 21), battery: 64);
  @override
  Future<void> suspend() async {}
  @override
  Future<void> close() async {}
}

/// Expands the 设置 section of the reading menu. The section keeps its state
/// across chapter changes, so this is a no-op while it is already open.
Future<void> _openSettings(WidgetTester tester) async {
  if (find.byTooltip('上一章').evaluate().isNotEmpty) return;
  await tester.tap(find.byKey(const ValueKey('reader-settings')));
  await tester.pumpAndSettle();
}
