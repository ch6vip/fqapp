import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/book_comment.dart';

/// Mirrors a live `/api/v1/books/{id}/comments` response: entries carry `text`
/// and a 0-10 integer `score`, while the page counters sit next to the list.
void main() {
  Map<String, dynamic> payload({Map<String, dynamic>? overrides}) => {
    'data': {
      'comment_cnt': 6530,
      'score_cnt': 26455,
      'context': '2.6万人点评',
      'has_more': true,
      'next_offset': 10,
      'comment': [
        {
          'comment_id': '7604874818993046297',
          'text': '作为一本甜文，实属上品。',
          'score': 10,
          'digg_count': 65,
          'reply_count': 4,
          'read_duration': 134062,
          'create_timestamp': 1756000000,
          'user_info': {
            'user_name': '惟有春来报',
            'user_avatar': 'https://example.test/a.jpg',
            'is_author': false,
          },
        },
        {
          'comment_id': '7604874818993046298',
          'text': '整体观感：青春校园文。',
          'score': 6,
          'digg_count': 50,
          'reply_count': 9,
          'read_duration': 3497,
          'create_timestamp': 1756000000,
          'user_info': {'user_name': '喵小姐的钟先生'},
        },
      ],
      ...?overrides,
    },
  };

  test('reads the page counters and the ready-made score label', () {
    final page = BookCommentPage.fromPayload(payload());
    expect(page.totalCount, 6530);
    expect(page.scoreCount, 26455);
    expect(page.scoreLabel, '2.6万人点评');
    expect(page.hasMore, isTrue);
    expect(page.nextOffset, 10);
    expect(page.headerLabel, '书评 · 6530');
  });

  test('builds a fallback score label when context is absent', () {
    final fallback = BookCommentPage.fromPayload(
      payload(overrides: {'context': '', 'score_cnt': 26455}),
    );
    expect(fallback.scoreLabel, '2.6万人点评');
    final counted = BookCommentPage.fromPayload(
      payload(overrides: {'context': '', 'score_cnt': 0}),
    );
    expect(counted.scoreLabel, '');
  });

  test('reads a comment body from text and its nested user', () {
    final page = BookCommentPage.fromPayload(payload());
    final first = page.comments.first;
    expect(first.id, '7604874818993046297');
    expect(first.text, '作为一本甜文，实属上品。');
    expect(first.userName, '惟有春来报');
    expect(first.userAvatar, 'https://example.test/a.jpg');
    expect(first.diggCount, 65);
    expect(first.replyCount, 4);
    expect(first.readSeconds, 134062);
    expect(first.createdAt, isNotNull);
  });

  test('maps the 0-10 upstream score onto five stars', () {
    final page = BookCommentPage.fromPayload(payload());
    expect(page.comments[0].stars, 5);
    expect(page.comments[1].stars, 3);
  });

  test('describes how long the reviewer had read', () {
    final page = BookCommentPage.fromPayload(payload());
    expect(page.comments[0].readDurationLabel, '阅读37小时后点评');
    expect(page.comments[1].readDurationLabel, '阅读58分钟后点评');
    expect(
      const BookComment(text: 'x', readSeconds: 20).readDurationLabel,
      '阅读20秒后点评',
    );
    expect(const BookComment(text: 'x').readDurationLabel, '');
  });

  group('relativeTime', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1756000000000);

    test('scales from minutes to years', () {
      String at(Duration ago) => BookComment(
        text: 'x',
        createdAt: now.subtract(ago),
      ).relativeTime(now: now);
      expect(at(const Duration(seconds: 10)), '刚刚');
      expect(at(const Duration(minutes: 5)), '5分钟前');
      expect(at(const Duration(hours: 3)), '3小时前');
      expect(at(const Duration(days: 1)), '1天前');
      expect(at(const Duration(days: 60)), '2个月前');
      expect(at(const Duration(days: 400)), '1年前');
    });

    test('is empty when no timestamp was supplied', () {
      expect(const BookComment(text: 'x').relativeTime(), '');
    });
  });

  test('drops entries without a body and tolerates a missing list', () {
    final page = BookCommentPage.fromPayload(
      payload(
        overrides: {
          'comment': [
            {'comment_id': '1', 'text': ''},
            {'comment_id': '2', 'text': '有效'},
          ],
        },
      ),
    );
    expect(page.comments, hasLength(1));
    expect(page.comments.single.text, '有效');
    expect(
      BookCommentPage.fromPayload(
        payload(overrides: {'comment': null}),
      ).comments,
      isEmpty,
    );
  });

  test('labels an empty page without a count', () {
    const page = BookCommentPage();
    expect(page.headerLabel, '书评');
    expect(page.scoreLabel, '');
    expect(page.isEmpty, isTrue);
  });

  test('accepts a nested data wrapper and unwraps a business error code', () {
    final page = BookCommentPage.fromPayload({'data': payload()});
    expect(page.totalCount, 6530);
    expect(isUnavailableCode(1301008), isTrue);
    expect(isUnavailableCode(0), isFalse);
    expect(isUnavailableCode(null), isFalse);
  });

  group('parseParagraphComments', () {
    /// Mirrors a live paragraph-comment response: a flat `data_list` whose
    /// entries nest everything under `comment`, counters included.
    Map<String, dynamic> paragraphPayload() => {
      'code': 0,
      'data': {
        'common_list_info': {'cursor': '400', 'has_more': false, 'total': 5},
        'data_list': [
          {
            'comment': {
              'comment_id': '7673571582642570046',
              'common': {
                'comment_type': 0,
                'content': {'text': '只为了自己'},
                'create_timestamp': 1786646180,
                'user_info': {
                  'base_info': {
                    'user_name': '星空、℡',
                    'user_avatar': 'https://example.test/u.heic',
                  },
                  'user_tag': {'is_author': true},
                },
              },
              'stat': {'digg_count': 9, 'reply_count': 2, 'read_duration': 61},
            },
          },
        ],
      },
    };

    test('reads the body, author and counters', () {
      final page = parseParagraphComments(paragraphPayload());
      expect(page.totalCount, 5);
      expect(page.hasMore, isFalse);
      expect(page.comments, hasLength(1));
      final comment = page.comments.single;
      expect(comment.text, '只为了自己');
      expect(comment.userName, '星空、℡');
      expect(comment.createdAt, isNotNull);
      // The counters live inside `comment`; reading a sibling `stat` reported
      // zero likes for every paragraph comment.
      expect(comment.diggCount, 9);
      expect(comment.replyCount, 2);
      expect(comment.readSeconds, 61);
      expect(comment.isAuthor, isTrue);
    });

    test('still accepts counters beside the comment', () {
      final page = parseParagraphComments({
        'code': 0,
        'data': {
          'data_list': [
            {
              'comment': {
                'comment_id': '1',
                'common': {
                  'content': {'text': '兄弟形式'},
                },
              },
              'stat': {'digg_count': 4},
            },
          ],
        },
      });
      expect(page.comments.single.diggCount, 4);
    });

    test('a business error yields an empty page', () {
      expect(parseParagraphComments({'code': 103001}).isEmpty, isTrue);
      expect(parseParagraphComments({'code': 0, 'data': {}}).isEmpty, isTrue);
    });

    test('entries without a body are dropped', () {
      final page = parseParagraphComments({
        'code': 0,
        'data': {
          'data_list': [
            {
              'comment': {
                'comment_id': '1',
                'common': {
                  'content': {'text': ''},
                },
              },
            },
            {
              'comment': {
                'comment_id': '2',
                'common': {
                  'content': {'text': '保留'},
                },
              },
            },
          ],
        },
      });
      expect(page.comments, hasLength(1));
      expect(page.comments.single.text, '保留');
    });
  });
}
