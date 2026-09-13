import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';

void main() {
  test('Fanqie picture groups keep images, dimensions, captions and order', () {
    final content = parseChapterContent(
      '<p>正文前半段。</p>'
      '<div data-fanqie-type="image" source="user">'
      '<p class="picture" group-id="9"><img src="https://images.test/a.webp?x-signature=a%2Bb%3D&amp;x-expires=9999999999" img-width="1400" img-height="2100"/></p>'
      '<p class="pictureDesc" group-id="9" idx="77">女主人设</p></div>'
      '<div data-fanqie-type="image" source="user"><img src="https://images.test/b.webp" img-width="1400" img-height="2103"/></div>'
      '<p>正文后半段。</p>',
    );
    expect(_sequence(content), ['正文前半段。', 'image', '女主人设', 'image', '正文后半段。']);
    expect(
      content.images.first.url,
      'https://images.test/a.webp?x-signature=a%2Bb%3D&x-expires=9999999999',
    );
    expect(content.images.first.aspectRatio, 2 / 3);
    expect(content.images.last.height, 2103);
    expect(content.legacyText, '正文前半段。\n女主人设\n正文后半段。');
  });

  test(
    'inline pictures split rendering without changing the old text anchor source',
    () {
      const source =
          '<p>前半<img src="https://images.test/a"/>后半<img src="https://images.test/a"/>结束</p>';
      final content = parseChapterContent(source);
      expect(_sequence(content), ['前半', 'image', '后半', 'image', '结束']);
      expect(content.legacyText, '前半后半结束');
      expect(content.images, hasLength(2));
    },
  );

  test(
    'cache round trips preserve literal markup and signed URLs exactly once',
    () {
      final content = parseChapterContent(
        '<p>&lt;b&gt;字面标签&lt;/b&gt; &amp;lt;br&amp;gt;</p>'
        '<img src="https://images.test/a?x-signature=a%2Bb%2Fc%3D&amp;k=1"/>',
      );
      final restored = ChapterContent.fromCacheText(content.toCacheText());
      expect(_sequence(restored), ['<b>字面标签</b> &lt;br&gt;', 'image']);
      expect(
        restored.images.single.url,
        'https://images.test/a?x-signature=a%2Bb%2Fc%3D&k=1',
      );
      expect(restored.legacyText, content.legacyText);
      expect(restored.illustrationsChecked, isTrue);
    },
  );

  test('old plain caches never interpret literal tags as new HTML', () {
    const text = '<img src="https://images.test/literal"/>\n&lt;b&gt;也是文字';
    final content = ChapterContent.fromCacheText(text);
    expect(content.images, isEmpty);
    expect(_sequence(content), text.split('\n'));
    expect(content.needsImageRefresh(), isTrue);
    expect(content.paragraphIdsChecked, isFalse);
  });

  test('legacy structured caches need paragraph ids only when absent', () {
    String legacyCache(List<Map<String, Object>> blocks) =>
        '\u001efqapp:chapter:2\n${jsonEncode({'version': 2, 'illustrationsChecked': true, 'legacyText': '第一章\n正文', 'blocks': blocks})}';
    final missing = ChapterContent.fromCacheText(
      legacyCache([
        {'type': 'text', 'text': '第一章'},
        {'type': 'text', 'text': '正文'},
      ]),
    );
    expect(missing.illustrationsChecked, isTrue);
    expect(missing.paragraphIdsChecked, isFalse);
    expect(missing.withoutLeadingTitle('第一章').paragraphIdsChecked, isFalse);
    expect(
      missing.blocks.whereType<ChapterParagraph>().map((p) => p.paraIndex),
      everyElement(isNull),
    );
    final indexed = ChapterContent.fromCacheText(
      legacyCache([
        {'type': 'text', 'text': '正文', 'idx': 9},
      ]),
    );
    expect(indexed.paragraphIdsChecked, isTrue);
    expect((indexed.blocks.single as ChapterParagraph).paraIndex, 9);
  });

  test('fresh markup without ids stays checked across cache round trips', () {
    final content = parseChapterContent('<h1>第一章</h1><p>正文</p>');
    final restored = ChapterContent.fromCacheText(content.toCacheText());
    expect(restored.paragraphIdsChecked, isTrue);
    expect(restored.withoutLeadingTitle('第一章').paragraphIdsChecked, isTrue);
    expect((restored.blocks.last as ChapterParagraph).paraIndex, isNull);
  });

  test('lazy sources, relative URLs and absent dimensions are supported', () {
    final content = parseChapterContent(
      '<img src="data:image/gif;base64,AAAA" data-src="//images.test/real.webp?a=1&amp;b=2" width="NaN" height="0"/>'
      '<img data-original="../next.png" width="400" height="100"/>',
      baseUrl: 'https://backend.test/chapter/1',
    );
    expect(content.images.first.url, 'https://images.test/real.webp?a=1&b=2');
    expect(content.images.first.aspectRatio, isNull);
    expect(content.images.last.url, 'https://backend.test/next.png');
    expect(content.images.last.aspectRatio, 4);
  });

  test(
    'hidden markup and invalid image schemes do not become network requests',
    () {
      final content = parseChapterContent(
        '<script><img src="https://images.test/hidden"/></script>'
        '<template><img src="https://images.test/template"/></template>'
        '<img src="javascript:alert(1)" alt="说明"/>'
        '<img src="file:///private/a.png"/><img src="https://user:password@images.test/a"/>'
        '<p>正文。</p>',
      );
      expect(content.images, isEmpty);
      expect(_sequence(content), ['说明', '正文。']);
    },
  );

  test(
    'an image-only chapter is readable and repeated images remain separate',
    () {
      final content = parseChapterContent(
        '<img src="https://images.test/a"/><img src="https://images.test/a"/>',
      );
      expect(content.isEmpty, isFalse);
      expect(content.images, hasLength(2));
      expect(content.withoutLeadingTitle('第一章').isEmpty, isFalse);
    },
  );

  test(
    'only the leading matching title is removed with adjacent images intact',
    () {
      final content = parseChapterContent(
        '<img src="https://images.test/a"/><h2>第 1 章</h2><p>正文</p><p>第1章</p>',
      ).withoutLeadingTitle('第1章');
      expect(_sequence(content), ['image', '正文', '第1章']);
      expect(content.legacyText, '正文\n第1章');
    },
  );

  test(
    'truncated or unsupported structured caches fail instead of showing JSON',
    () {
      final encoded = ChapterContent.fromPlainText(
        '正文',
        illustrationsChecked: true,
      ).toCacheText();
      expect(
        () => ChapterContent.fromCacheText(
          encoded.substring(0, encoded.length - 3),
        ),
        throwsFormatException,
      );
      expect(
        () => ChapterContent.fromCacheText(
          encoded.replaceFirst('"version":2', '"version":99'),
        ),
        throwsFormatException,
      );
    },
  );

  test('expired signatures and incomplete sources are refreshable', () {
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
    expect(
      parseChapterContent('<p>正文</p>').needsImageRefresh(now: now),
      isFalse,
    );
    expect(
      ChapterContent.fromPlainText('旧缓存').needsImageRefresh(now: now),
      isTrue,
    );
  });

  test(
    'API uses the decrypted illustration source and encodes chapter IDs',
    () async {
      final requests = <Uri>[];
      final api = ApiClient(
        baseUrl: 'http://backend.test',
        client: MockClient((request) async {
          requests.add(request.url);
          return _json({
            'code': 0,
            'data': {
              'content_decrypted': true,
              'content': '<p>正文</p><img src="https://images.test/a"/>',
            },
          });
        }),
      );
      final content = await api.chapterContent('chapter/with?reserved&chars');
      expect(requests.single.pathSegments, [
        'api',
        'v1',
        'chapters',
        'chapter/with?reserved&chars',
        'novel',
      ]);
      expect(content.images, hasLength(1));
      expect(content.illustrationsChecked, isTrue);
    },
  );

  for (final unavailable in ['ciphertext', 'failure', 'empty']) {
    test(
      'API $unavailable falls back to readable text and marks it incomplete',
      () async {
        final paths = <String>[];
        final api = ApiClient(
          baseUrl: 'http://backend.test',
          client: MockClient((request) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/novel')) {
              return switch (unavailable) {
                'failure' => _json({
                  'code': 500,
                  'message': 'unavailable',
                }, status: 500),
                'empty' => _json({
                  'code': 0,
                  'data': {
                    'content_decrypted': true,
                    'content': '<script>hidden</script>',
                  },
                }),
                _ => _json({
                  'code': 0,
                  'data': {'content': 'encryptedBytesMustNotReachTheReader'},
                }),
              };
            }
            return _json({
              'code': 200,
              'data': {'content': '<p>&lt;b&gt;正文&lt;/b&gt;</p>'},
            });
          }),
        );
        final content = await api.chapterContent('chapter');
        expect(paths, ['/api/v1/chapters/chapter/novel', '/api/content']);
        expect(_sequence(content), ['<b>正文</b>']);
        expect(content.illustrationsChecked, isFalse);
      },
    );
  }

  test('API image-only chapters do not fall back to the text source', () async {
    var count = 0;
    final api = ApiClient(
      baseUrl: 'http://backend.test',
      client: MockClient((request) async {
        count++;
        return _json({
          'code': 0,
          'data': {
            'content_decrypted': true,
            'content': '<img src="https://images.test/a"/>',
          },
        });
      }),
    );
    expect((await api.chapterContent('chapter')).images, hasLength(1));
    expect(count, 1);
  });
}

List<String> _sequence(ChapterContent content) => [
  for (final block in content.blocks)
    switch (block) {
      ChapterParagraph() => block.text,
      ChapterImage() => 'image',
    },
];

http.Response _json(Object payload, {int status = 200}) => http.Response(
  jsonEncode(payload),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
