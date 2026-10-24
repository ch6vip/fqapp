import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'support/fakes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/text_replacement_engine.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'local reader applies rules and restores original without rewriting source',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
      final store = TextReplacementStore();
      await store.save(
        enabled: true,
        rules: [
          const TextReplacementRule(id: 'a', pattern: '漂亮国', replacement: '美国'),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            bookId: 'local:replacement',
            title: 'Book',
            chapters: [Chapter(itemId: 'c', title: 'Chapter', volumeName: '')],
            startIndex: 0,
            localOnly: true,
            chapterLoader: (_) async => '他来到了漂亮国。',
            readerStore: MemoryReaderStore(),
            replacementStore: store,
          ),
        ),
      );
      for (
        var i = 0;
        i < 100 && find.textContaining('他来到了美国。').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.textContaining('他来到了美国。'), findsOneWidget);
      await store.save(enabled: false, rules: store.snapshot.rules);
      await tester.pumpAndSettle();
      expect(find.textContaining('他来到了漂亮国。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'rule change during cache refresh uses the latest original text',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
      final store = TextReplacementStore();
      final chapter = Chapter(itemId: 'c', title: 'C', volumeName: '');
      await store.save(
        enabled: true,
        rules: [
          const TextReplacementRule(
            id: 'a',
            pattern: 'old',
            replacement: 'OLD',
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            bookId: 'b',
            title: 'Book',
            chapters: [chapter],
            startIndex: 0,
            chapterCache: MemoryChapterCache(),
            chapterLoader: (_) async => 'old original',
            readerStore: MemoryReaderStore(),
            replacementStore: store,
          ),
        ),
      );
      Future<void> waitFor(String text) async {
        for (
          var i = 0;
          i < 150 && find.textContaining(text).evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(find.textContaining(text), findsOneWidget);
      }

      await waitFor('OLD original');
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存'));
      await tester.pumpAndSettle();
      final sheet = tester.widget<ChapterCacheSheet>(
        find.byType(ChapterCacheSheet),
      );
      sheet.onContentAvailable!(
        chapter,
        ChapterContent.fromPlainText(
          'new original',
          illustrationsChecked: true,
        ).toCacheText(),
      );
      await store.save(
        enabled: true,
        rules: [
          const TextReplacementRule(
            id: 'a',
            pattern: 'new',
            replacement: 'NEW',
          ),
        ],
      );
      Navigator.pop(tester.element(find.byType(ChapterCacheSheet)));
      await waitFor('NEW original');
      expect(find.textContaining('old original'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('fully removed chapter offers a way to disable replacement', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
    final store = TextReplacementStore();
    await store.save(
      enabled: true,
      rules: [
        const TextReplacementRule(id: 'a', pattern: 'body', replacement: ''),
      ],
    );
    await tester.runAsync(
      () => TextReplacementEngine.instance.transform(
        source: ChapterContent.fromPlainText(
          'body',
          illustrationsChecked: true,
        ),
        chapterTitle: 'C',
        snapshot: store.snapshot,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          bookId: 'local:empty',
          title: 'Book',
          chapters: [Chapter(itemId: 'c', title: 'C', volumeName: '')],
          startIndex: 0,
          localOnly: true,
          chapterLoader: (_) async => 'body',
          readerStore: MemoryReaderStore(),
          replacementStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本章正文已被替换规则清空'), findsOneWidget);
    await tester.tap(find.text('停用正文替换'));
    await tester.pumpAndSettle();
    expect(find.textContaining('body'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('cancelled older refresh cannot overwrite newer disk cache', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
    final engine = _DelayedReplacementEngine();
    final store = TextReplacementStore();
    final cache = MemoryChapterCache();
    final chapter = Chapter(itemId: 'c', title: 'C', volumeName: '');
    final original = ChapterContent.fromPlainText('old').toCacheText();
    final a = ChapterContent.fromPlainText(
      'A',
      illustrationsChecked: true,
    ).toCacheText();
    final b = ChapterContent.fromPlainText(
      'B',
      illustrationsChecked: true,
    ).toCacheText();
    await cache.write(bookId: 'b', chapterId: 'c', title: 'C', text: original);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          bookId: 'b',
          title: 'Book',
          chapters: [chapter],
          startIndex: 0,
          chapterCache: cache,
          chapterLoader: (_) async => a,
          readerStore: MemoryReaderStore(),
          replacementStore: store,
          replacementEngine: engine,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(engine.waiting, isNotNull);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存'));
    await tester.pumpAndSettle();
    final sheet = tester.widget<ChapterCacheSheet>(
      find.byType(ChapterCacheSheet),
    );
    sheet.onContentAvailable!(chapter, b);
    await cache.write(bookId: 'b', chapterId: 'c', title: 'C', text: b);
    engine.release();
    await tester.pumpAndSettle();
    expect(cache.content['b']!['c'], b);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  ReaderLayoutSpec spec() => ReaderLayoutSpec(
    viewport: const Size(360, 640),
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  );
  test(
    'raw v2 offsets survive replacements, images and repeated title text',
    () async {
      final source = parseChapterContent(
        '<p>Title</p><p idx="3">xABCz</p><img src="https://example.com/a.png"><p>Title</p><p>tail</p>',
      );
      final result = await TextReplacementEngine.instance.transform(
        source: source,
        chapterTitle: 'Title',
        snapshot: TextReplacementSnapshot(
          enabled: true,
          revision: 1,
          rules: [
            const TextReplacementRule(
              id: '1',
              pattern: 'ABC',
              replacement: 'B',
            ),
          ],
        ),
      );
      final raw = ReaderChapterLayout(
        title: 'Title',
        content: source,
        spec: spec(),
      );
      final layout = ReaderChapterLayout(
        title: 'Title',
        content: source,
        spec: spec(),
        replacement: result,
      );
      expect(layout.blocks.map((b) => b.text), [
        'Title',
        'xBz',
        '\uFFFC',
        'Title',
        'tail',
      ]);
      final tailSource = raw.blocks.last.start;
      expect(
        layout.displayOffsetForSource(tailSource),
        layout.blocks.last.start,
      );
      expect(
        layout.sourceOffsetForDisplay(layout.blocks.last.start),
        tailSource,
      );
      final restored = layout.restore(
        {'chapterId': 'c', 'positionVersion': 2, 'textOffset': tailSource},
        chapterId: 'c',
        startAtEnd: false,
        paged: true,
      );
      expect(restored.textOffset, layout.blocks.last.start);
      expect(
        layout.sourceTextInRange(
          raw.blocks[1].start + 1,
          raw.blocks[1].start + 4,
        ),
        'ABC',
      );
    },
  );
  test(
    'deleted paragraph keeps following fallback identity and scroll stays valid',
    () async {
      final source = ChapterContent.fromPlainText('remove\nkeep');
      final result = await TextReplacementEngine.instance.transform(
        source: source,
        chapterTitle: '',
        snapshot: TextReplacementSnapshot(
          enabled: true,
          revision: 1,
          rules: [
            const TextReplacementRule(
              id: '1',
              pattern: 'remove',
              replacement: '',
            ),
          ],
        ),
      );
      final layout = ReaderChapterLayout(
        title: '',
        content: source,
        spec: spec(),
        replacement: result,
      );
      expect(layout.blocks[1].lines, isEmpty);
      expect(layout.blocks[2].textId, -2);
      expect(layout.scrollForTextOffset(0), isNonNegative);
      expect(layout.pages, isNotEmpty);
      expect(layout.displayOffsetForSource(3), layout.blocks[2].start);
    },
  );
}

class _DelayedReplacementEngine extends TextReplacementEngine {
  Completer<TextReplacementResult>? waiting;
  TextReplacementResult? delayed;
  void release() => waiting!.complete(delayed!);
  @override
  Future<TextReplacementResult> transform({
    required ChapterContent source,
    required String chapterTitle,
    required TextReplacementSnapshot snapshot,
    TextReplacementCancellation? cancellation,
  }) async {
    final result = TextReplacementResult(
      source: source,
      content: source,
      snapshotRevision: snapshot.revision,
    );
    if ((source.blocks.first as ChapterParagraph).text == 'A') {
      delayed = result;
      waiting = Completer<TextReplacementResult>();
      return waiting!.future;
    }
    return result;
  }
}
