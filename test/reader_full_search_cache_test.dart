import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_full_search.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/reader/reader_full_search_panel.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

final _chapters = [
  for (var i = 0; i < 8; i++)
    Chapter(itemId: '$i', title: '第$i章', volumeName: ''),
];
String _cacheText(String value) => ChapterContent.fromPlainText(
  value,
  illustrationsChecked: true,
).toCacheText();

Future<ReaderFullSearchPanel> _mountSearch(
  WidgetTester tester, {
  required String bookId,
  required MemoryChapterCache cache,
  ChapterTextLoader? loader,
  bool localOnly = true,
}) async {
  setSingleChapterPrefs({'reader_page_mode': 'scroll'});
  final style = AppThemeStyleStore();
  await style.select(AppThemeStyle.classic);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    style.dispose();
  });
  await tester.pumpWidget(
    AppUiHost(
      store: style,
      home: ReaderPage(
        bookId: bookId,
        title: '来源缓存测试',
        chapters: _chapters,
        startIndex: 0,
        localOnly: localOnly,
        chapterLoader: loader,
        chapterCache: cache,
        readerStore: MemoryReaderStore(),
        readerDevice: _Device(),
        replacementStore: TextReplacementStore(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tapAt(
    tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('reader-classic-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('classic-reader-full-search')));
  await tester.pumpAndSettle();
  return tester.widget<ReaderFullSearchPanel>(
    find.byType(ReaderFullSearchPanel),
  );
}

Map<String, int> _callCounts(List<String> calls) => {
  for (final id in calls.toSet())
    id: calls.where((called) => called == id).length,
};

ReaderFullSearchController _controller(ReaderFullSearchPanel panel) {
  expect(panel.loadChapterForSearch, isNotNull);
  final clock = TestWidgetsFlutterBinding.instance.clock;
  final started = clock.now();
  final controller = ReaderFullSearchController(
    networkElapsed: () => clock.now().difference(started),
    chapters: panel.chapters,
    loadChapter: panel.loadChapter,
    loadChapterForSearch: panel.loadChapterForSearch,
  );
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _search(
  WidgetTester tester,
  ReaderFullSearchController controller,
  String query,
) async {
  var finished = false;
  final task = controller.search(query).then((_) => finished = true);
  for (var i = 0; i < 12 && !finished; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  expect(finished, isTrue, reason: 'Eight serial chapter loads must finish');
  await task;
}

void main() {
  testWidgets(
    'Shuqi persists more than five chapters and reuses only its source cache',
    (tester) async {
      const id = 'shuqi:42';
      final cache = MemoryChapterCache();
      cache.content['42'] = {
        for (final chapter in _chapters)
          chapter.itemId: _cacheText('foreign cache'),
      };
      cache.content[id] = {
        '3': _cacheText('needle cached chapter'),
        // A title-only cache is not usable chapter content.
        '4': _cacheText(_chapters[4].title),
      };
      cache.pinned[id] = {'3'};
      final calls = <String>[];
      final panel = await _mountSearch(
        tester,
        bookId: id,
        cache: cache,
        loader: (chapter) async {
          calls.add(chapter.itemId);
          return 'needle downloaded chapter ${chapter.itemId}';
        },
      );
      final controller = _controller(panel);
      await _search(tester, controller, 'needle');
      expect(controller.state.failedChapters, isEmpty);
      expect(controller.state.matchCount, 8);
      expect(_callCounts(calls), {
        for (final id in ['0', '1', '2', '4', '5', '6', '7']) id: 1,
      }, reason: 'Foreground, prefetch and search share one request per miss');
      expect(cache.content[id]!.length, 8);
      expect(cache.catalogs[id]!.chapters.length, 8);
      expect(cache.pinned[id], {'3'});
      expect(cache.content['42']!['4'], _cacheText('foreign cache'));
      final firstCalls = List.of(calls);
      await _search(tester, controller, 'chapter');
      expect(controller.state.matchCount, 8);
      expect(calls, firstCalls, reason: 'Evicted memory entries reuse disk');
      expect(tester.takeException(), isNull);
    },
  );

  for (final localOnly in [false, true]) {
    testWidgets('imported files bypass remote cache (localOnly=$localOnly)', (
      tester,
    ) async {
      const id = 'local_123_abcd';
      final cache = MemoryChapterCache();
      cache.content[id] = {
        for (final chapter in _chapters)
          chapter.itemId: _cacheText('foreign stale cache'),
      };
      final calls = <String>[];
      final panel = await _mountSearch(
        tester,
        bookId: id,
        cache: cache,
        localOnly: localOnly,
        loader: (chapter) async {
          calls.add(chapter.itemId);
          return 'needle local file ${chapter.itemId}';
        },
      );
      final controller = _controller(panel);
      var finished = false;
      final task = controller.search('needle').then((_) => finished = true);
      // Only zero-delay scan yields are needed, with no 300ms network waits.
      for (var i = 0; i < 30 && !finished; i++) {
        await tester.pump(const Duration(microseconds: 1));
      }
      expect(finished, isTrue);
      await task;
      expect(controller.state.matchCount, 8);
      expect(controller.state.failedChapters, isEmpty);
      expect(_callCounts(calls), {for (final c in _chapters) c.itemId: 1});
      final firstCalls = List.of(calls);
      await _search(tester, controller, 'local');
      expect(controller.state.matchCount, 8);
      expect(
        _callCounts(calls),
        {for (final c in _chapters) c.itemId: c.itemId == '0' ? 1 : 2},
        reason:
            'Sequential reads reuse the current chapter and reload evicted files',
      );
      expect(calls.length, firstCalls.length + 7);
      expect(cache.catalogs, isEmpty);
      expect(cache.content[id]!.values.toSet(), {
        _cacheText('foreign stale cache'),
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('storage failure keeps fetched search text usable', (
    tester,
  ) async {
    final calls = <String>[];
    final panel = await _mountSearch(
      tester,
      bookId: 'shuqi:storage-error',
      cache: _FailingCache(),
      loader: (chapter) async {
        calls.add(chapter.itemId);
        return 'needle downloaded chapter ${chapter.itemId}';
      },
    );
    final controller = _controller(panel);
    await _search(tester, controller, 'needle');
    expect(controller.state.matchCount, 8);
    expect(controller.state.failedChapters, isEmpty);
    expect(_callCounts(calls), {for (final c in _chapters) c.itemId: 1});
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached Shuqi misses require a source loader', (tester) async {
    final cache = MemoryChapterCache();
    cache.content['shuqi:offline'] = {
      '0': _cacheText('needle cached chapter'),
      '1': _cacheText('needle prefetched chapter'),
    };
    final panel = await _mountSearch(
      tester,
      bookId: 'shuqi:offline',
      cache: cache,
    );
    final errors = <Object>[];
    final controller = ReaderFullSearchController(
      chapters: [_chapters[2]],
      loadChapter: panel.loadChapter,
      loadChapterForSearch: (chapter, cancellation) async {
        try {
          return await panel.loadChapterForSearch!(chapter, cancellation);
        } catch (error) {
          errors.add(error);
          rethrow;
        }
      },
    );
    addTearDown(controller.dispose);
    await _search(tester, controller, 'needle');
    expect(controller.state.failedChapters, [_chapters[2]]);
    expect(
      errors.single,
      isA<ApiException>().having(
        (error) => error.message,
        'source-specific error',
        contains('此来源的章节未缓存'),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel during pacing starts no further uncached download', (
    tester,
  ) async {
    final calls = <String>[];
    final panel = await _mountSearch(
      tester,
      bookId: 'shuqi:cancel',
      cache: MemoryChapterCache(),
      loader: (chapter) async {
        calls.add(chapter.itemId);
        return 'needle chapter ${chapter.itemId}';
      },
    );
    final controller = _controller(panel);
    var finished = false;
    final task = controller.search('needle').then((_) => finished = true);
    for (var i = 0; i < 20 && calls.length < 3; i++) {
      await tester.pump(const Duration(microseconds: 1));
    }
    expect(calls, ['0', '1', '2']);
    controller.cancel();
    await tester.pump();
    expect(finished, isTrue);
    await task;
    await tester.pump(const Duration(seconds: 1));
    expect(calls, ['0', '1', '2']);
    expect(controller.state.cancelled, isTrue);
    expect(controller.state.failedChapters, isEmpty);
  });
}

class _FailingCache extends MemoryChapterCache {
  @override
  Future<String?> read({
    required String bookId,
    required String chapterId,
  }) async => throw StateError('disk unavailable');

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async => throw StateError('disk full');
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(time: DateTime(2026), battery: 64);
  @override
  Future<void> keepScreenOn(bool on) async {}
  @override
  Future<void> setImmersive(
    bool enabled, {
    bool showStatusBar = false,
    bool showNavigationBar = false,
  }) async {}
  @override
  Future<void> close() async {}
}
