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
  });
}
