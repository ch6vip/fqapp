import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/text_replacement_engine.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'find retains exact display coordinates inside a single expanded paragraph',
    (tester) async {
      setSingleChapterPrefs({'reader_page_mode': 'paged'});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        await tester.binding.setSurfaceSize(null);
      });
      const bookId = 'local:find-replacement';
      const title = '甲章';
      const marker = '短标';
      const target = '唯一末端命中';
      final expanded =
          '${List.filled(100, '山风吹过窗台，书页在阳光下缓缓翻开。').join()}'
          '$target，故事仍在继续。';
      final replacements = TextReplacementStore();
      final engine = TextReplacementEngine();
      final cache = MemoryChapterCache();
      final marks = _Bookmarks();
      await replacements.save(
        enabled: true,
        rules: [
          TextReplacementRule(
            id: 'expand',
            pattern: marker,
            replacement: expanded,
          ),
        ],
      );
      final source = ChapterContent.fromPlainText(
        marker,
        illustrationsChecked: true,
      );
      await cache.write(
        bookId: bookId,
        chapterId: 'a',
        title: title,
        text: source.toCacheText(),
      );
      // Warm the real engine outside fake async. The reader receives the same
      // serialized source, so it can reuse the transform without an isolate wait.
      final transformed = await tester.runAsync(
        () => engine.transform(
          source: source,
          chapterTitle: title,
          snapshot: replacements.snapshot,
        ),
      );
      expect(transformed, isNotNull);
      expect(transformed!.error, isNull);
      expect(transformed.source, same(source));
      expect(
        (transformed.source.blocks.single as ChapterParagraph).text,
        marker,
      );
      expect(
        (transformed.content.blocks.single as ChapterParagraph).text,
        expanded,
      );

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: true, highContrast: true),
            child: PerformanceScope(
              preferences: const PerformancePreferences(enabled: true),
              explicitReduceMotion: true,
              child: child!,
            ),
          ),
          home: ReaderPage(
            bookId: bookId,
            title: '查找替换回归',
            chapters: [Chapter(itemId: 'a', title: title, volumeName: '')],
            startIndex: 0,
            localOnly: true,
            chapterLoader: (_) async => source.toCacheText(),
            readerStore: MemoryReaderStore(),
            readerDevice: _Device(),
            chapterCache: cache,
            replacementStore: replacements,
            replacementEngine: engine,
            bookmarkStore: marks,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final layout = _pager(tester).layout;
      final body = layout.blocks.where((b) => !b.isTitle && !b.isImage).single;
      expect(body.text, expanded);
      final matchStart = body.start + body.text.indexOf(target);
      final matchEnd = matchStart + target.length;
      final expectedPage = layout.pageForOffset(matchStart);
      final sourceStart = layout.sourceOffsetForDisplay(matchStart);
      final sourceEnd = layout.sourceOffsetForDisplay(
        matchEnd,
        bias: TextBoundaryBias.end,
      );
      final lossyPage = layout.pageForOffset(
        layout.displayOffsetForSource(sourceStart),
      );
      expect(expectedPage, greaterThan(0));
      expect(
        lossyPage,
        0,
        reason: 'The old round trip loses the in-marker hit.',
      );
      expect(layout.sourceTextInRange(sourceStart, sourceEnd), marker);

      await _showControls(tester);
      await tester.tap(find.byKey(const ValueKey('reader-find-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        target,
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('reader-find-result-0')));
      await tester.pumpAndSettle();
      final landed = _pager(tester);
      expect(landed.pageIndex, expectedPage);
      expect(landed.pageIndex, isNot(lossyPage));
      expect(landed.selection?.start, matchStart);
      expect(landed.selection?.end, matchEnd);
      expect(find.text('正文已更新，请重新查找'), findsNothing);

      // Find uses display coordinates, but bookmarks still persist source offsets.
      final pageSource = layout.sourceOffsetForDisplay(
        layout.pages[expectedPage].start,
      );
      await _showControls(tester);
      await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-add-bookmark')));
      await tester.pumpAndSettle();
      expect(marks.entries, hasLength(1));
      expect(marks.entries.single.chapterId, 'a');
      expect(marks.entries.single.sourceOffset, pageSource);
      expect(marks.entries.single.sourceOffset, sourceStart);
      expect(source.legacyText, marker);
      expect(
        ChapterContent.fromCacheText(cache.content[bookId]!['a']!).legacyText,
        marker,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

ReaderPagedView _pager(WidgetTester tester) =>
    tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));

Future<void> _showControls(WidgetTester tester) async {
  if (find
      .byKey(const ValueKey('reader-find-entry'))
      .hitTestable()
      .evaluate()
      .isEmpty) {
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pumpAndSettle();
  }
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

class _Bookmarks extends ReaderBookmarkStore {
  final entries = <ReaderBookmark>[];
  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async =>
      entries.where((mark) => mark.bookId == bookId).toList();
  @override
  Future<void> add(ReaderBookmark mark) async {
    entries.removeWhere((entry) => entry.key == mark.key);
    entries.add(mark);
    changes.value++;
  }

  @override
  Future<void> remove(String key) async {
    entries.removeWhere((entry) => entry.key == key);
    changes.value++;
  }
}
