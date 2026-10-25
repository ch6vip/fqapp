import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

/// `audioTimePointLayoutRange`: the 听书 timeline's `(paraId, offset)` range
/// turned into absolute layout offsets.
///
/// `start_para` is the upstream `<p idx="N">` id, **not** a display ordinal —
/// the two disagree whenever the markup carries marker-only or empty
/// paragraphs, and treating the id as an ordinal is exactly what lit the wrong
/// text before. The end offset is inclusive upstream, so callers pass `+1`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('audioTimePointLayoutRange (听书 -> layout offsets)', () {
    test('resolves by paragraph id, not by display order', () {
      // Ids deliberately out of step with position: idx 5 is the first body
      // paragraph. An ordinal-based lookup would resolve paraId 5 to the third
      // block instead.
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。', paraIndex: 3),
          const ChapterParagraph('第二句。', paraIndex: 5),
        ],
      );
      // '第二句。' is 4 chars; the inclusive end offset for the whole
      // paragraph is 3, and the caller adds 1.
      final range = audioTimePointLayoutRange(layout, 5, 0, 5, 3 + 1);
      expect(range, isNotNull);
      expect(_textAt(layout, range!), '第二句。');
    });

    test('a paragraph id the layout does not render yields null', () {
      // Marker-only and empty paragraphs consume ids without producing a block,
      // so a timeline point can address an id this chapter has no text for.
      final layout = _layout(
        title: '第一章',
        blocks: [const ChapterParagraph('第一句。', paraIndex: 0)],
      );
      expect(audioTimePointLayoutRange(layout, 7, 0, 7, 3), isNull);
    });

    test('the inclusive end offset covers the last character', () {
      final layout = _layout(
        title: '第一章',
        blocks: [const ChapterParagraph('第一句。', paraIndex: 2)],
      );
      // Upstream would send end_para_off = 3 for the whole 4-char paragraph;
      // the caller adds 1, giving the half-open range [0, 4).
      final range = audioTimePointLayoutRange(layout, 2, 0, 2, 4);
      expect(_textAt(layout, range!), '第一句。');
    });

    test('a range spanning two paragraphs covers both ends', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。第二句。', paraIndex: 10),
          const ChapterParagraph('第三句。', paraIndex: 20),
        ],
      );
      // From the 5th char of the first paragraph to the 4th of the second
      // (inclusive end 3, plus the caller's +1).
      final range = audioTimePointLayoutRange(layout, 10, 4, 20, 3 + 1);
      expect(range, isNotNull);
      // The paragraph separator is a gap between block offsets, not block text,
      // so the covered text is the two slices back to back.
      expect(_textAt(layout, range!), '第二句。第三句。');
    });

    test('image blocks consume layout space without taking a paragraph id', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          const ChapterParagraph('第一句。', paraIndex: 1),
          const ChapterImage(url: 'cover.png'),
          const ChapterParagraph('第二句。', paraIndex: 2),
        ],
      );
      final range = audioTimePointLayoutRange(layout, 2, 0, 2, 4);
      expect(range, isNotNull);
      expect(_textAt(layout, range!), '第二句。');
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
      // The timeline can overshoot when the upstream counted differently; the
      // highlight must stay inside the paragraph rather than run into the next.
      final range = audioTimePointLayoutRange(layout, 0, 0, 0, 999);
      expect(range, isNotNull);
      expect(_textAt(layout, range!), '第一句。');
    });
  });

  group('positionV2 element narrowing', () {
    test('element_offset resolves inside the addressed <blk>', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          ChapterParagraph(
            '甲乙丙丁戊己',
            paraIndex: 4,
            // Two inline elements: [0,3) is e_idx 0, [3,6) is e_idx 1.
            blkSpans: const [
              ChapterBlkSpan(elementIndex: 0, start: 0, length: 3),
              ChapterBlkSpan(elementIndex: 1, start: 3, length: 3),
            ],
          ),
        ],
      );
      // e_idx 1, offset 1 → paragraph offset 4 → the fifth character.
      final range = audioTimePointLayoutRange(
        layout,
        4,
        0,
        4,
        6,
        startElementIndex: 1,
        startElementOffset: 1,
      );
      expect(_textAt(layout, range!), '戊己');
    });

    test('a negative element index means the offset is already the paragraph offset', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          ChapterParagraph(
            '甲乙丙丁戊己',
            paraIndex: 4,
            blkSpans: const [
              ChapterBlkSpan(elementIndex: 0, start: 0, length: 3),
            ],
          ),
        ],
      );
      // Official `S(-1, x)` returns x unchanged.
      final range = audioTimePointLayoutRange(
        layout,
        4,
        2,
        4,
        6,
        startElementIndex: -1,
        startElementOffset: 2,
      );
      expect(_textAt(layout, range!), '丙丁戊己');
    });

    test('an unknown element falls back to the paragraph offset', () {
      final layout = _layout(
        title: '第一章',
        blocks: [
          ChapterParagraph(
            '甲乙丙丁戊己',
            paraIndex: 4,
            blkSpans: const [
              ChapterBlkSpan(elementIndex: 0, start: 0, length: 3),
            ],
          ),
        ],
      );
      // Every point also carries the paragraph-level pair, so a missing element
      // degrades in precision rather than landing somewhere wrong.
      final range = audioTimePointLayoutRange(
        layout,
        4,
        1,
        4,
        6,
        startElementIndex: 9,
        startElementOffset: 0,
      );
      expect(_textAt(layout, range!), '乙丙丁戊己');
    });
  });
}

/// The layout text covered by [range], separators included, so a test can assert
/// exactly which characters the highlight paints.
String _textAt(ReaderChapterLayout layout, ({int start, int end}) range) {
  final buffer = StringBuffer();
  for (final block in layout.blocks) {
    final blockEnd = block.start + block.text.length;
    final from = range.start.clamp(block.start, blockEnd) - block.start;
    final to = range.end.clamp(block.start, blockEnd) - block.start;
    if (to > from) buffer.write(block.text.substring(from, to));
  }
  return buffer.toString();
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
