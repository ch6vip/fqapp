import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/chapter_summary.dart';

/// Recorded from a live `/api/v1/books/{id}/chapters/summary?item_ids=` response.
///
/// The field is named `summary`, but the value is the chapter's own opening
/// text — hence the UI presents it as a preview.
Map<String, dynamic> _payload() => {
  'code': 0,
  'data': {
    'summary_item_data': [
      {
        'is_review': false,
        'item_id': '7491705434915488318',
        'summary': '“对不起......”“老子是兔子啊，特么全是素！”',
      },
      {'is_review': false, 'item_id': '2', 'summary': '第二章的开头'},
    ],
  },
};

void main() {
  group('ChapterSummary', () {
    test('keys excerpts by chapter item id', () {
      final summary = ChapterSummary.fromPayload(_payload());
      expect(summary.byItemId, hasLength(2));
      expect(
        summary.forItem('7491705434915488318'),
        '“对不起......”“老子是兔子啊，特么全是素！”',
      );
      expect(summary.forItem('2'), '第二章的开头');
    });

    test('an unknown chapter has no excerpt', () {
      final summary = ChapterSummary.fromPayload(_payload());
      expect(summary.forItem('missing'), isNull);
    });

    test('entries without an id or text are dropped', () {
      final summary = ChapterSummary.fromPayload({
        'code': 0,
        'data': {
          'summary_item_data': [
            {'item_id': '', 'summary': '没有 id'},
            {'item_id': '1', 'summary': ''},
            {'item_id': '2', 'summary': '保留'},
          ],
        },
      });
      expect(summary.byItemId, hasLength(1));
      expect(summary.forItem('2'), '保留');
    });

    test('a business error yields an empty summary', () {
      expect(ChapterSummary.fromPayload({'code': 100001}).isEmpty, isTrue);
      expect(ChapterSummary.empty.isEmpty, isTrue);
      expect(ChapterSummary.empty.isNotEmpty, isFalse);
    });

    test('a malformed payload yields an empty summary', () {
      expect(ChapterSummary.fromPayload({'code': 0}).isEmpty, isTrue);
      expect(
        ChapterSummary.fromPayload({'code': 0, 'data': 'x'}).isEmpty,
        isTrue,
      );
      expect(
        ChapterSummary.fromPayload({
          'code': 0,
          'data': {'summary_item_data': 'x'},
        }).isEmpty,
        isTrue,
      );
    });

    test('a payload with no usable entries is empty', () {
      expect(
        ChapterSummary.fromPayload({
          'code': 0,
          'data': {
            'summary_item_data': [
              {'item_id': '1', 'summary': '  '},
            ],
          },
        }).isEmpty,
        isTrue,
      );
    });

    test('audio content markers are stripped from the preview', () {
      final summary = ChapterSummary.fromPayload({
        'code': 0,
        'data': {
          'summary_item_data': [
            {
              'item_id': 'a',
              'summary':
                  '{!-- PGC_VOICE:{"content":"","duration":"664.79",'
                  '"source_provider":"audiobook"}--}第一章的正文开头',
            },
            {
              'item_id': 'b',
              'summary': '<!-- PGC_VOICE:{"duration":"1"} -->第二章的正文',
            },
          ],
        },
      });
      expect(summary.forItem('a'), '第一章的正文开头');
      expect(summary.forItem('b'), '第二章的正文');
    });

    test('a marker-only preview is dropped instead of shown raw', () {
      final summary = ChapterSummary.fromPayload({
        'code': 0,
        'data': {
          'summary_item_data': [
            {
              'item_id': 'a',
              'summary': '{!-- PGC_VOICE:{"content":"","duration":"664.79"',
            },
          ],
        },
      });
      expect(summary.forItem('a'), isNull);
      expect(summary.isEmpty, isTrue);
    });

    test('html tags and entities are cleaned', () {
      final summary = ChapterSummary.fromPayload({
        'code': 0,
        'data': {
          'summary_item_data': [
            {'item_id': 'a', 'summary': '<p>你好&amp;世界</p>\n第二行'},
          ],
        },
      });
      expect(summary.forItem('a'), '你好&世界 第二行');
    });

    test('a truncated audio marker keeps the text that follows it', () {
      final summary = ChapterSummary.fromPayload({
        'code': 0,
        'data': {
          'summary_item_data': [
            {
              'item_id': 'a',
              'summary': '{!-- PGC_VOICE:{"content":"","duration":"664.79"}正文',
            },
          ],
        },
      });
      expect(summary.forItem('a'), '正文');
    });

    test('plain comparison characters are not treated as html', () {
      final summary = ChapterSummary.fromPayload({
        'code': 0,
        'data': {
          'summary_item_data': [
            {'item_id': 'a', 'summary': '当 1 < 2 > 0 时'},
          ],
        },
      });
      expect(summary.forItem('a'), '当 1 < 2 > 0 时');
    });
  });
}
