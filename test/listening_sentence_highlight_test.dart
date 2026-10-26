import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_text_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('narrationLayoutRange (TTS -> layout offsets)', () {
    test('first sentence shifts by the title prefix', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。第二句。', paraIndex: 0),
          const ChapterParagraph('第三句。', paraIndex: 1),
        ],
      );
      // TTS text: '第一句。第二句。\n第三句。' — title stripped.
      // Layout: title block [0,3), separator, body starts at 4.
      expect(
        narrationLayoutRange(layout, (start: 0, end: 4)),
        (start: 4, end: 8),
      );
    });

    test('range spanning the paragraph separator covers both blocks', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。第二句。', paraIndex: 0),
          const ChapterParagraph('第三句。', paraIndex: 1),
        ],
      );
      // TTS [5, 11): '二句。\n第三' — crosses the '\n' at TTS offset 8.
      expect(
        narrationLayoutRange(layout, (start: 5, end: 11)),
        (start: 9, end: 15),
      );
    });

    test('separator-only range maps to nothing', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。', paraIndex: 0),
          const ChapterParagraph('第二句。', paraIndex: 1),
        ],
      );
      // TTS offset 4 is the '\n' between the two paragraphs.
      expect(narrationLayoutRange(layout, (start: 4, end: 5)), isNull);
    });

    test('image blocks consume layout space but no TTS space', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterImage(url: 'https://example.invalid/1.png'),
          const ChapterParagraph('第一句。第二句。', paraIndex: 0),
          const ChapterParagraph('第三句。', paraIndex: 1),
        ],
      );
      // Layout: title [0,3), '\n', image placeholder [4,5), '\n', body at 6.
      // TTS: '第一句。第二句。\n第三句。' — the image is invisible to TTS.
      expect(
        narrationLayoutRange(layout, (start: 0, end: 4)),
        (start: 6, end: 10),
      );
      expect(
        narrationLayoutRange(layout, (start: 9, end: 12)),
        (start: 15, end: 18),
      );
    });

    test('empty title contributes no offset', () {
      final layout = _layout(
        title: '',
        blocks: [const ChapterParagraph('第一句。', paraIndex: 0)],
      );
      expect(
        narrationLayoutRange(layout, (start: 0, end: 4)),
        (start: 0, end: 4),
      );
    });

    test('out-of-range TTS range maps to nothing', () {
      final layout = _layout(
        title: '第一章',
        blocks: [const ChapterParagraph('第一句。', paraIndex: 0)],
      );
      expect(narrationLayoutRange(layout, (start: 100, end: 104)), isNull);
    });
  });

  group('ReaderBlockMarkLayer narration wash', () {
    testWidgets('passes the block-local narration range to the painter', (
      tester,
    ) async {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。第二句。第三句。', paraIndex: 0),
        ],
      );
      final block = layout.blocks[1];
      final scope = ReaderSelectionScope(
        geometry: ReaderSelectionGeometry(),
        washColor: Colors.blue,
        handleColor: Colors.blue,
        underlineColor: Colors.blue,
        narrationColor: Colors.amber,
      );
      final spec = layout.spec;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderBlockMarkLayer(
            block: block,
            spec: spec,
            scope: scope,
            selection: null,
            rangeUnderlines: const [],
            // Chapter coords: title [0,3), separator, body starts at 4;
            // '第二句。' is layout [8,12).
            narrationRange: (8, 12),
            child: const SizedBox(width: 300, height: 100),
          ),
        ),
      );
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<ReaderBlockMarkPainter>()
          .toList();
      expect(painters, hasLength(1));
      // Block-local: body block starts at 4, so (8,12) -> (4,8).
      expect(painters.single.narrationRange, (4, 8));
      expect(painters.single.narrationColor, Colors.amber);
      expect(tester.takeException(), isNull);
    });
  });

  group('ReaderPagedView narration range', () {
    testWidgets('forwards the range to the mark layers', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final layout = _layout(
        title: '第一章',
        blocks: [
          ChapterParagraph(
            List.filled(20, '第一句。第二句。第三句。').join(),
            paraIndex: 0,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPagedView(
              layout: layout,
              pageIndex: 0,
              hasPreviousChapter: false,
              hasNextChapter: false,
              onPageChanged: (_) {},
              onBoundary: (_) async {},
              onDragStart: () {},
              turnStyle: ReaderPageTurnStyle.none,
              backgroundColor: Colors.white,
              narrationRange: (4, 8),
              selectionScope: ReaderSelectionScope(
                geometry: ReaderSelectionGeometry(),
                washColor: Colors.blue,
                handleColor: Colors.blue,
                underlineColor: Colors.blue,
                narrationColor: Colors.amber,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<ReaderBlockMarkPainter>()
          .where((p) => p.narrationRange != null)
          .toList();
      expect(painters, isNotEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('ReaderPagedView follow anchor', () {
    testWidgets('followOffset lands on the page holding the offset', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // Long enough to span several pages, so a proportional jump and an
      // offset-based jump cannot land on the same page by accident.
      final layout = _layout(
        title: '第一章',
        blocks: [
          ChapterParagraph(
            List.filled(120, '第一句。第二句。第三句。').join(),
            paraIndex: 0,
          ),
        ],
      );
      final key = GlobalKey<ReaderPagedViewState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPagedView(
              key: key,
              layout: layout,
              pageIndex: 0,
              hasPreviousChapter: false,
              hasNextChapter: false,
              onPageChanged: (_) {},
              onBoundary: (_) async {},
              onDragStart: () {},
              turnStyle: ReaderPageTurnStyle.none,
              backgroundColor: Colors.white,
            ),
          ),
        ),
      );
      await tester.pump();
      final pages = layout.pages.length;
      expect(pages, greaterThan(2));
      final offset = layout.pages[pages - 1].start;
      expect(key.currentState!.currentPage, 0);
      key.currentState!.followOffset(offset);
      await tester.pump();
      await tester.pump();
      expect(layout.pageForOffset(offset), pages - 1);
      expect(key.currentState!.currentPage, pages - 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('ListeningSession sentenceRange', () {
    setUp(ListeningSession.instance.clear);
    tearDown(ListeningSession.instance.clear);

    test('update stores the range, clear resets it', () {
      final session = ListeningSession.instance;
      session.update(
        bookId: 'b',
        chapterId: 'c',
        chapterTitle: '第一章',
        position: Duration.zero,
        duration: Duration.zero,
        playing: true,
        sentenceRange: (start: 10, end: 20),
      );
      expect(session.sentenceRange, (start: 10, end: 20));
      session.clear();
      expect(session.sentenceRange, isNull);
    });

    test('update without a range clears it (audiobook path)', () {
      final session = ListeningSession.instance;
      session.update(
        bookId: 'b',
        chapterId: 'c',
        chapterTitle: '第一章',
        position: Duration.zero,
        duration: Duration.zero,
        playing: true,
        sentenceRange: (start: 10, end: 20),
      );
      session.update(
        bookId: 'b',
        chapterId: 'c',
        chapterTitle: '第一章',
        position: const Duration(seconds: 5),
        duration: const Duration(seconds: 60),
        playing: true,
      );
      expect(session.sentenceRange, isNull);
    });
  });

  group('narrationHighlight preference', () {
    test('defaults to on and persists off', () async {
      SharedPreferences.setMockInitialValues({});
      expect((await ReaderPreferences.load()).narrationHighlight, isTrue);
      SharedPreferences.setMockInitialValues({
        'reader_narration_highlight': false,
      });
      expect((await ReaderPreferences.load()).narrationHighlight, isFalse);
    });
  });
}

ReaderChapterLayout _layout({
  required String title,
  required List<ChapterBlock> blocks,
}) {
  const viewport = Size(400, 800);
  final spec = ReaderLayoutSpec(
    viewport: viewport,
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  );
  return ReaderChapterLayout(
    title: title,
    content: ChapterContent(blocks: blocks),
    spec: spec,
  );
}
