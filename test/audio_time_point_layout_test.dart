import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

/// `audioTimePointLayoutRange`: the 听书 timeline's (paragraph, offset) range
/// turned into absolute layout offsets.
///
/// The backend numbers body paragraphs from zero and excludes the title, while
/// the layout is `[title, ...body]` with image blocks interleaved. Every case
/// here is an off-by-one that would light up the wrong sentence on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('audioTimePointLayoutRange (听书 -> layout offsets)', () {
    test('paragraph 0 is the first body paragraph, after the title', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。第二句。', paraIndex: 0),
          const ChapterParagraph('第三句。', paraIndex: 1),
        ],
      );
      // Layout: title [0,3), separator at 3, body starts at 4.
      // Paragraph 0, offsets 0..4 → layout 4..8.
      expect(audioTimePointLayoutRange(layout, 0, 0, 0, 4), (start: 4, end: 8));
    });

    test('a later paragraph resolves against its own block start', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。第二句。', paraIndex: 0),
          const ChapterParagraph('第三句。', paraIndex: 1),
        ],
      );
      // Paragraph 1, offsets 0..3 → layout 13..16 (4 + 8 + 1 separator).
      expect(audioTimePointLayoutRange(layout, 1, 0, 1, 3), (
        start: 13,
        end: 16,
      ));
    });

    test('a range spanning two paragraphs covers both ends', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。第二句。', paraIndex: 0),
          const ChapterParagraph('第三句。', paraIndex: 1),
        ],
      );
      // From paragraph 0 offset 4 to paragraph 1 offset 3.
      expect(audioTimePointLayoutRange(layout, 0, 4, 1, 3), (
        start: 8,
        end: 16,
      ));
    });

    test('image blocks consume layout space but not paragraph numbers', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。', paraIndex: 0),
          const ChapterImage(url: 'cover.png'),
          const ChapterParagraph('第二句。', paraIndex: 1),
        ],
      );
      // Paragraph 1 must land after the body text *and* the image placeholder;
      // counting the image as a paragraph would shift the highlight.
      final range = audioTimePointLayoutRange(layout, 1, 0, 1, 3);
      expect(range, isNotNull);
      final blockText = layout.blocks
          .where((b) => !b.isImage)
          .firstWhere((b) => b.text.startsWith('第二句'))
          .text;
      expect(blockText, '第二句。');
      expect(range!.end - range.start, 3);
    });

    test('a paragraph the layout does not have yields null', () {
      final layout = _layout(
        title: '第一章',
        blocks: [const ChapterParagraph('第一句。', paraIndex: 0)],
      );
      // Stale timeline: the chapter text shrank since the audio was generated.
      expect(audioTimePointLayoutRange(layout, 5, 0, 5, 3), isNull);
    });

    test('an empty range yields null rather than a zero-width highlight', () {
      final layout = _layout(
        title: '第一章',
        blocks: [const ChapterParagraph('第一句。', paraIndex: 0)],
      );
      expect(audioTimePointLayoutRange(layout, 0, 2, 0, 2), isNull);
    });

    test('offsets past the paragraph clamp to its end', () {
      final layout = _layout(
        title: '第一章',
        blocks: [const ChapterParagraph('第一句。', paraIndex: 0)],
      );
      // The timeline can overshoot when the backend counted differently.
      final range = audioTimePointLayoutRange(layout, 0, 0, 0, 999);
      expect(range, isNotNull);
      expect(range!.end - range.start, 4);
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
