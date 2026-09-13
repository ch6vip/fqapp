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

  test('an image-alt caption does not hide the leading title', () {
    final body = parseChapterContent(
      '<img src="javascript:alert(1)" alt="插图"/><h1>第一章</h1><p>正文</p>',
    ).withoutLeadingTitle('第一章');
    expect(
      body.blocks.whereType<ChapterParagraph>().map((p) => p.text).toList(),
      ['插图', '正文'],
    );
    expect(splitChapterParagraphs(body.legacyText), ['插图', '正文']);
  });

  test('a non-leading paragraph equal to the title is kept', () {
    final body = parseChapterContent(
      '<p>序</p><p>第一章</p><p>正文</p>',
    ).withoutLeadingTitle('第一章');
    expect(
      body.blocks.whereType<ChapterParagraph>().map((p) => p.text).toList(),
      ['序', '第一章', '正文'],
    );
    expect(splitChapterParagraphs(body.legacyText), ['序', '第一章', '正文']);
  });

  test('a caption that shares the title text is not the one removed', () {
    final body = parseChapterContent(
      '<img src="javascript:alert(1)" alt="第一章"/><h1>第一章</h1><p>正文</p>',
    ).withoutLeadingTitle('第一章');
    expect(
      body.blocks.whereType<ChapterParagraph>().map((p) => p.text).toList(),
      ['第一章', '正文'],
    );
    expect(splitChapterParagraphs(body.legacyText), ['第一章', '正文']);
  });

  test('a caption keeps a later body title out of the legacy removal', () {
    final body = parseChapterContent(
      '<img src="javascript:alert(1)" alt="图注"/>'
      '<h1>第一章</h1><p>正文</p><p>第一章</p>',
    ).withoutLeadingTitle('第一章');
    expect(
      body.blocks.whereType<ChapterParagraph>().map((p) => p.text).toList(),
      ['图注', '正文', '第一章'],
    );
    expect(splitChapterParagraphs(body.legacyText), ['图注', '正文', '第一章']);
  });

  test('the image-alt caption flag survives a structured cache round trip', () {
    final content = parseChapterContent(
      '<img src="javascript:alert(1)" alt="插图"/><h1>第一章</h1><p>正文</p>',
    );
    final body = ChapterContent.fromCacheText(
      content.toCacheText(),
    ).withoutLeadingTitle('第一章');
    expect(
      body.blocks.whereType<ChapterParagraph>().map((p) => p.text).toList(),
      ['插图', '正文'],
    );
    expect(splitChapterParagraphs(body.legacyText), ['插图', '正文']);
  });
}
