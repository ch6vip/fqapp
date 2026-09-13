import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';

void main() {
  test('image URLs with malformed escapes never break needsImageRefresh', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
    final content = parseChapterContent(
      '<img src="https://images.test/a?x=%FF"/>',
    );
    expect(content.images, hasLength(1));
    expect(() => content.needsImageRefresh(now: now), returnsNormally);
    expect(content.needsImageRefresh(now: now), isFalse);
  });

  test('a valid x-expires query is still honoured', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
    expect(
      parseChapterContent(
        '<img src="https://images.test/a?x-expires=1000050"/>',
      ).needsImageRefresh(now: now),
      isTrue,
    );
    expect(
      parseChapterContent(
        '<img src="https://images.test/a?x-expires=1001000"/>',
      ).needsImageRefresh(now: now),
      isFalse,
    );
  });

  test('a br inside an inline wrapper does not duplicate the paragraph id', () {
    List<int?> ids(String source) => parseChapterContent(
      source,
    ).blocks.whereType<ChapterParagraph>().map((p) => p.paraIndex).toList();
    expect(ids('<p idx="1"><span>a<br></span>b</p>'), [1, null]);
    expect(ids('<p idx="1"><span><em>a<br></em>b</span>c</p>'), [1, null]);
    // Without a break every inline child still belongs to the one upstream id.
    expect(ids('<p idx="1"><span>a</span>b</p>'), [1]);
    // A direct break already consumed the id for the following text.
    expect(ids('<p idx="1">a<br>b</p>'), [1, null]);
  });

  test('a usable image keeps its alt out of the legacy anchor', () {
    final content = parseChapterContent(
      '<img src="https://images.test/a" alt="说明"/><p>正文</p>',
    );
    expect(
      content.blocks.whereType<ChapterParagraph>().map((p) => p.text).toList(),
      ['正文'],
    );
    expect(splitChapterParagraphs(content.legacyText), ['正文']);
  });
}
