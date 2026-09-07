import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';

void main() {
  test(
    'block elements and attributed breaks preserve paragraph boundaries',
    () {
      expect(
        normalizeChapterText(
          '<article><h2>第一章</h2>'
          '<DIV>第一<span>段</span>。</DIV>'
          '<div>第二段。<BR data-reader="break > here">第三段。</div>'
          '<p>第四<strong>段</strong>。</p><hr><p>第五段。</p></article>',
        ),
        '第一章\n第一段。\n第二段。\n第三段。\n第四段。\n第五段。',
      );
    },
  );

  test('HTML paragraphs with omitted closing tags stay separate', () {
    expect(
      normalizeChapterText('<p>第一段。<p>第二段。<div>第三段。</div>'),
      '第一段。\n第二段。\n第三段。',
    );
  });

  test(
    'named and numeric entities decode before line separators are split',
    () {
      expect(
        normalizeChapterText(
          '<p>&emsp;&emsp;&ldquo;开始&rdquo;&#10;下一段&#x2029;'
          'Tom&nbsp;&amp;&nbsp;Jerry</p>',
        ),
        '“开始”\n下一段\nTom & Jerry',
      );
    },
  );

  test('comments and hidden markup do not enter the chapter', () {
    expect(
      normalizeChapterText(
        '<style>p { color: red; }</style><p>正文。</p>'
        '<!-- 换行 <br> 说明 --><script>ignore("<p>广告</p>");</script>'
        '<template>隐藏文字</template><p>下一段。</p>',
      ),
      '正文。\n下一段。',
    );
  });

  test('plain comparisons and Chinese angle-bracket text survive cleanup', () {
    expect(
      normalizeChapterText('判断 1 < 2 且 3 > 1。\n<技能面板>：已解锁。'),
      '判断 1 < 2 且 3 > 1。\n<技能面板>：已解锁。',
    );
  });

  test(
    'reader does not parse or decode already-normalized cache text again',
    () {
      final text = normalizeChapterText(
        '<p>&lt;b&gt;是书中的字面标签&lt;/b&gt;，&amp;lt;br&amp;gt;也保留。</p>',
      );
      expect(text, '<b>是书中的字面标签</b>，&lt;br&gt;也保留。');
      expect(splitChapterParagraphs(text), [text]);
    },
  );

  test(
    'cached plain text supports all line separators without blank paragraphs',
    () {
      expect(
        splitChapterParagraphs(
          '\uFEFF　第一段\r\n\r\n\t第二段\r第三段\u0085'
          '第四段\u2028第五段\u2029\u200B\n第六段　',
        ),
        ['第一段', '第二段', '第三段', '第四段', '第五段', '第六段'],
      );
    },
  );

  test(
    'only an exact leading chapter title is removed from body paragraphs',
    () {
      expect(
        splitChapterParagraphs(
          '第 1 章 到来\n正文第一段。\n第1章 到来\n后面的段落。',
          chapterTitle: '第1章 到来',
        ),
        ['正文第一段。', '第1章 到来', '后面的段落。'],
      );
      expect(splitChapterParagraphs('第一章的故事才刚开始。', chapterTitle: '第一章'), [
        '第一章的故事才刚开始。',
      ]);
    },
  );

  test(
    'punctuation, word spaces and joined emoji do not create new paragraphs',
    () {
      const paragraph = '“得，果然是顶级贵族学校。”  Next chapter: 👩‍👩‍👧‍👦。';
      expect(normalizeChapterText(paragraph), paragraph);
      expect(splitChapterParagraphs(paragraph), [paragraph]);
    },
  );
}
