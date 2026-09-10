import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';

/// Shapes mirror live responses: `idea/list` returns a map keyed by paragraph
/// index (counts and comment ids only), while the comment list returns
/// `data_list[i].comment` with `stat` beside it.
void main() {
  group('ChapterIdeas', () {
    Map<String, dynamic> payload({dynamic code = 0}) => {
      'code': code,
      'data': {
        'item_version': '',
        'data': {
          '0': {
            'bubble_data': {
              '0': {'channel': 43, 'count': 0},
              '1': {'channel': 0, 'count': 287},
              '3': {'channel': 0, 'count': 287},
            },
            'count': 287,
            'hot': '0',
            'infos': <dynamic>[],
            'is_author_comment': false,
            'user_count': 0,
          },
          '28': {
            'bubble_data': {
              '0': {'channel': 43, 'count': 0},
              '1': {'channel': 0, 'count': 4},
            },
            'count': 4,
            'hot': '0',
            'infos': [
              {'comment_id': '7580233808075719486'},
              {'comment_id': '7546956646142984985'},
            ],
            'is_author_comment': false,
            'user_count': 0,
          },
          '3': {
            'bubble_data': <String, dynamic>{},
            'count': 0,
            'infos': <dynamic>[],
          },
        },
      },
    };

    test('reads the per-paragraph counts', () {
      final ideas = ChapterIdeas.fromPayload(payload());
      expect(ideas.paragraphs, hasLength(3));
      expect(ideas.forParagraph(0)?.count, 287);
      expect(ideas.forParagraph(28)?.count, 4);
      expect(ideas.total, 291);
    });

    test('sorts paragraphs and exposes only the ones with ideas', () {
      final ideas = ChapterIdeas.fromPayload(payload());
      expect(ideas.paragraphs.map((p) => p.paraIndex).toList(), [0, 3, 28]);
      expect(ideas.withIdeas.map((p) => p.paraIndex).toList(), [0, 28]);
    });

    test('keeps the per-channel bubble counters', () {
      // The paragraph-comment channel (43) can report 0 even when the paragraph
      // has ideas, which is why the count and the channel are separate.
      final first = ChapterIdeas.fromPayload(payload()).forParagraph(0)!;
      expect(first.count, 287);
      expect(first.countForChannel(43), 0);
      expect(first.countForChannel(1), 287);
      expect(first.countForChannel(99), 0);
    });

    test('exposes the comment ids without inventing bodies', () {
      final ideas = ChapterIdeas.fromPayload(payload());
      final entry = ideas.forParagraph(28)!;
      expect(entry.commentIds, ['7580233808075719486', '7546956646142984985']);
      expect(ideas.forParagraph(0)!.commentIds, isEmpty);
    });

    test('degrades to empty on business error codes', () {
      expect(ChapterIdeas.fromPayload(payload(code: 103001)).isEmpty, isTrue);
      expect(ChapterIdeas.fromPayload(payload(code: 1301008)).isEmpty, isTrue);
      expect(isUnavailableIdeaCode(103001), isTrue);
      expect(isUnavailableIdeaCode(0), isFalse);
      expect(isUnavailableIdeaCode(null), isFalse);
    });

    test('degrades to empty on unexpected payloads', () {
      expect(ChapterIdeas.fromPayload(const {}).isEmpty, isTrue);
      expect(
        ChapterIdeas.fromPayload(const {
          'code': 0,
          'data': {'data': {}},
        }).isEmpty,
        isTrue,
      );
      expect(
        ChapterIdeas.fromPayload(const {
          'code': 0,
          'data': {'data': 'nope'},
        }).isEmpty,
        isTrue,
      );
    });

    test('tolerates entries without bubble data or ids', () {
      final ideas = ChapterIdeas.fromPayload(const {
        'code': 0,
        'data': {
          'data': {
            '5': {'count': '12'},
          },
        },
      });
      final entry = ideas.forParagraph(5)!;
      expect(entry.count, 12);
      expect(entry.channelCounts, isEmpty);
      expect(entry.commentIds, isEmpty);
    });
  });

  group('parseParagraphComments', () {
    Map<String, dynamic> payload({dynamic code = 0}) => {
      'code': code,
      'data': {
        'common_list_info': {
          'cursor': '{"session_id":"20260911","offset":20}',
          'has_more': true,
          'total': 12,
        },
        'data_list': [
          {
            'comment': {
              'comment_id': '7580233808075719486',
              'common': {
                'content': {'text': '这段写得好'},
                'create_timestamp': 1756000000,
                'user_info': {
                  'base_info': {
                    'user_name': '读者甲',
                    'user_avatar': 'https://a.test/x.jpg',
                  },
                },
              },
            },
            'stat': {'digg_count': 7, 'reply_count': 2},
            'data_type': 0,
          },
          {
            'comment': {
              'comment_id': 'empty-body',
              'common': {
                'content': {'text': ''},
              },
            },
            'stat': {'digg_count': 0, 'reply_count': 0},
          },
        ],
      },
    };

    test('normalizes the nested comment and stat wrappers', () {
      final page = parseParagraphComments(payload());
      expect(page.comments, hasLength(1));
      final comment = page.comments.single;
      expect(comment.id, '7580233808075719486');
      expect(comment.text, '这段写得好');
      expect(comment.userName, '读者甲');
      expect(comment.userAvatar, 'https://a.test/x.jpg');
      expect(comment.diggCount, 7);
      expect(comment.replyCount, 2);
      expect(comment.createdAt, isNotNull);
    });

    test('reads the page counters and cursor offset', () {
      final page = parseParagraphComments(payload());
      expect(page.totalCount, 12);
      expect(page.hasMore, isTrue);
      expect(page.nextOffset, 20);
      expect(page.headerLabel, '书评 · 12');
    });

    test('drops entries without a body', () {
      final page = parseParagraphComments(payload());
      expect(page.comments.map((c) => c.id), ['7580233808075719486']);
    });

    test('degrades to an empty page', () {
      expect(parseParagraphComments(payload(code: 103001)).isEmpty, isTrue);
      expect(parseParagraphComments(const {}).isEmpty, isTrue);
      expect(
        parseParagraphComments(const {
          'code': 0,
          'data': {'data_list': 'nope'},
        }).isEmpty,
        isTrue,
      );
    });
  });
}
