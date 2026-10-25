import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';

/// The 听书 timeline addresses paragraphs by the upstream `<p idx="N">` id, so
/// the parser has to carry that id through — and the ids are **not** display
/// ordinals: marker-only and empty paragraphs consume ids without producing a
/// block. These cases pin that behaviour on markup shaped like the real thing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('paragraph ids survive the parse', () {
    test('a marker-only paragraph consumes an id without emitting a block', () {
      // The audiobook header paragraph carries only the PGC_VOICE marker, and
      // the following <p> is empty. Ids 0 and 2 are therefore absent from the
      // blocks while the text starts at id 1 — exactly why the timeline's
      // max start_para exceeds the block count.
      final content = parseChapterContent(
        '<p idx="0">{!-- PGC_VOICE:{"title":"001 大巴"} --}</p><p></p>'
        '<div class="novel-fm-asr">'
        '<p idx="1">本节目由番茄畅听出品。</p>'
        '<p idx="3">浓雾中，</p>'
        '</div>',
      );
      final ids = content.blocks
          .whereType<ChapterParagraph>()
          .map((p) => p.paraIndex)
          .toList();
      expect(ids, [1, 3]);
    });

    test('ids are not recoverable from display order', () {
      // Two paragraphs, ids 5 and 9: an implementation that counts blocks would
      // resolve id 9 to the second block by luck and id 5 to nothing.
      final content = parseChapterContent(
        '<p idx="5">第一段。</p><p idx="9">第二段。</p>',
      );
      final paras = content.blocks.whereType<ChapterParagraph>().toList();
      expect(paras.map((p) => p.paraIndex), [5, 9]);
    });
  });

  group('<blk> element spans', () {
    test('records each inline element with its e_idx', () {
      final content = parseChapterContent(
        '<p idx="4">'
        '<blk p_idx="4" e_idx="0" e_order="0">甲乙丙</blk>'
        '<blk p_idx="4" e_idx="1" e_order="1">丁戊己</blk>'
        '</p>',
      );
      final para = content.blocks.whereType<ChapterParagraph>().single;
      expect(para.text, '甲乙丙丁戊己');
      expect(para.blkSpans, hasLength(2));
      expect(para.blkSpans[0].elementIndex, 0);
      expect(para.blkSpans[0].start, 0);
      expect(para.blkSpans[0].length, 3);
      expect(para.blkSpans[1].elementIndex, 1);
      expect(para.blkSpans[1].start, 3);
      expect(para.blkSpans[1].length, 3);
    });

    test('spans are located in the emitted text after trimming', () {
      // The paragraph normalisation trims edges, so the recorded element text is
      // what gets searched for — a raw offset would point at the whitespace.
      final content = parseChapterContent(
        '<p idx="2">  <blk e_idx="0">甲乙丙</blk>  </p>',
      );
      final para = content.blocks.whereType<ChapterParagraph>().single;
      expect(para.text, '甲乙丙');
      expect(para.blkSpans, hasLength(1));
      expect(para.blkSpans.single.start, 0);
      expect(para.blkSpans.single.length, 3);
    });

    test('markup without <blk> records no spans', () {
      final content = parseChapterContent('<p idx="1">没有块标签。</p>');
      final para = content.blocks.whereType<ChapterParagraph>().single;
      expect(para.blkSpans, isEmpty);
    });
  });

  group('cache round-trip', () {
    test('blk spans survive toCacheText / fromCacheText', () {
      final content = parseChapterContent(
        '<p idx="4">'
        '<blk e_idx="0">甲乙丙</blk><blk e_idx="1">丁戊己</blk>'
        '</p>',
      );
      final restored = ChapterContent.fromCacheText(content.toCacheText());
      final para = restored.blocks.whereType<ChapterParagraph>().single;
      expect(para.paraIndex, 4);
      expect(para.blkSpans, hasLength(2));
      expect(para.blkSpans[1].elementIndex, 1);
      expect(para.blkSpans[1].start, 3);
      expect(para.blkSpans[1].length, 3);
    });

    test('a cache written without spans still loads', () {
      // Old caches have no 'blk' key; they must keep working, just without
      // element-level precision.
      final content = parseChapterContent('<p idx="1">只有文字。</p>');
      final cache = content.toCacheText();
      final stripped = cache.replaceAll(RegExp(r',?\s*"blk":\[[^\]]*\]'), '');
      final restored = ChapterContent.fromCacheText(stripped);
      final para = restored.blocks.whereType<ChapterParagraph>().single;
      expect(para.text, '只有文字。');
      expect(para.blkSpans, isEmpty);
    });
  });
}
