import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/comment_reply.dart';

/// Recorded from a live `/api/v1/comments/{id}/replies` response. The body sits
/// under `Common` with a capital C.
Map<String, dynamic> _payload({bool hasMore = false, int total = 2}) => {
  'code': 0,
  'data': {
    'reply_list': [
      {
        'reply_id': '7538174107558331161',
        'Common': {
          'comment_type': 0,
          'content': {'text': '插眼'},
          'create_timestamp': 1755132718,
          'user_info': {
            'base_info': {
              'user_id': '321516697821774',
              'user_name': '羡长生.^',
              'user_avatar': 'https://example.test/u.heic',
            },
          },
        },
        'stat': {'digg_count': 3, 'reply_count': 0},
      },
      {
        'reply_id': '2',
        'Common': {
          'content': {'text': '不就是虐文吗？等我消息'},
          'create_timestamp': 1755132718,
          'user_info': {
            'base_info': {'user_name': '^沈菥.'},
          },
        },
        'stat': {'digg_count': 3},
      },
    ],
    'comment_list_info': {'cursor': '5', 'has_more': hasMore, 'total': total},
  },
};

void main() {
  group('CommentReplyPage', () {
    test('reads the replies with their author and digg count', () {
      final page = CommentReplyPage.fromPayload(_payload());
      expect(page.replies, hasLength(2));
      final first = page.replies.first;
      expect(first.id, '7538174107558331161');
      expect(first.text, '插眼');
      expect(first.userName, '羡长生.^');
      expect(first.userAvatar, 'https://example.test/u.heic');
      expect(first.diggCount, 3);
    });

    test('accepts the lowercase common key too', () {
      final page = CommentReplyPage.fromPayload({
        'code': 0,
        'data': {
          'reply_list': [
            {
              'reply_id': '1',
              'common': {
                'content': {'text': '小写'},
              },
            },
          ],
        },
      });
      expect(page.replies.single.text, '小写');
    });

    test('reads the total and the more flag', () {
      final page = CommentReplyPage.fromPayload(
        _payload(hasMore: true, total: 5),
      );
      expect(page.totalCount, 5);
      expect(page.hasMore, isTrue);
      expect(page.cursor, '5');
      expect(page.headerLabel, '共 5 条回复');
    });

    test('playlet replies use common_list_info for count and pagination', () {
      final payload = _payload();
      final data = payload['data'] as Map<String, dynamic>;
      data.remove('comment_list_info');
      data['common_list_info'] = {
        'cursor': 'reply-cursor',
        'has_more': true,
        'total': 17,
      };
      final page = CommentReplyPage.fromPayload(payload);
      expect(page.replies, hasLength(2));
      expect(page.totalCount, 17);
      expect(page.hasMore, isTrue);
      expect(page.cursor, 'reply-cursor');
    });

    test('a zero total still yields a header', () {
      final page = CommentReplyPage.fromPayload(_payload(total: 0));
      expect(page.headerLabel, '回复');
    });

    test('parses the publish time from seconds', () {
      final reply = CommentReplyPage.fromPayload(_payload()).replies.first;
      expect(reply.createdAt, isNotNull);
      // 1755132718 is a plausible 2025 timestamp, not a 1970 one.
      expect(reply.createdAt!.year, greaterThan(2020));
    });

    test('relative time reads in Chinese units', () {
      final now = DateTime(2026, 9, 11, 12);
      CommentReply at(Duration ago) =>
          CommentReply(text: 'x', createdAt: now.subtract(ago));
      expect(at(const Duration(seconds: 30)).relativeTime(now: now), '刚刚');
      expect(at(const Duration(minutes: 5)).relativeTime(now: now), '5分钟前');
      expect(at(const Duration(hours: 3)).relativeTime(now: now), '3小时前');
      expect(at(const Duration(days: 2)).relativeTime(now: now), '2天前');
      expect(at(const Duration(days: 60)).relativeTime(now: now), '2个月前');
      expect(at(const Duration(days: 400)).relativeTime(now: now), '1年前');
    });

    test('a reply without a timestamp has no relative time', () {
      expect(const CommentReply(text: 'x').relativeTime(), '');
    });

    test('replies without text are dropped', () {
      final page = CommentReplyPage.fromPayload({
        'code': 0,
        'data': {
          'reply_list': [
            {
              'reply_id': '1',
              'Common': {
                'content': {'text': ''},
              },
            },
            {'reply_id': '2', 'Common': {}},
            {'reply_id': '3'},
            {
              'reply_id': '4',
              'Common': {
                'content': {'text': '保留'},
              },
            },
          ],
        },
      });
      expect(page.replies, hasLength(1));
      expect(page.replies.single.text, '保留');
    });

    test('a business error yields an empty page', () {
      expect(CommentReplyPage.fromPayload({'code': 103001}).isEmpty, isTrue);
      expect(CommentReplyPage.empty.isEmpty, isTrue);
      expect(CommentReplyPage.empty.isNotEmpty, isFalse);
    });

    test('a malformed payload yields an empty page', () {
      expect(CommentReplyPage.fromPayload({'code': 0}).isEmpty, isTrue);
      expect(
        CommentReplyPage.fromPayload({'code': 0, 'data': 'x'}).isEmpty,
        isTrue,
      );
    });

    test('a missing user still yields usable text', () {
      final page = CommentReplyPage.fromPayload({
        'code': 0,
        'data': {
          'reply_list': [
            {
              'reply_id': '1',
              'Common': {
                'content': {'text': '匿名'},
              },
            },
          ],
        },
      });
      expect(page.replies.single.text, '匿名');
      expect(page.replies.single.userName, '');
      expect(page.replies.single.userAvatar, '');
      expect(page.replies.single.diggCount, 0);
    });
  });
}
