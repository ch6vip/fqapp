import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/book_comment.dart';

/// Regression tests for B13 (audio/comment model parsing).
///
/// Covers the upstream `cover` field on related short-drama entries, and the
/// numeric helpers in [BookComment]/[AudioTone] that must degrade instead of
/// throwing `Error`s on non-finite JSON numbers or out-of-range timestamps.
void main() {
  group('RelatedWork cover parsing', () {
    test('uses video_data.cover when the other cover fields are absent', () {
      final works = RelatedWork.fromPayload({
        'data': {
          'cell_data': [
            {
              'cell_name': 'related works',
              'book_data': [
                {
                  'book_id': '1',
                  'book_name': 'novel',
                  'thumb_url': 'https://example.test/n.jpg',
                },
              ],
              'video_data': [
                {
                  'series_id': '2',
                  'title': 'drama',
                  'cover': 'https://example.test/v.jpg',
                  'horiz_cover': '',
                },
              ],
            },
          ],
        },
      });

      expect(works, hasLength(2));
      expect(works[0].cover, 'https://example.test/n.jpg');
      expect(works[1].cover, 'https://example.test/v.jpg');
    });
  });

  group('BookComment numeric guards', () {
    test('non-finite counters degrade to 0 instead of throwing', () {
      final raw = <String, dynamic>{
        'text': 'x',
        'digg_count': jsonDecode('1e309'),
        'reply_count': double.nan,
        'read_duration': double.infinity,
      };

      expect(() => BookComment.fromRaw(raw), returnsNormally);
      final comment = BookComment.fromRaw(raw);
      expect(comment, isNotNull);
      expect(comment!.diggCount, 0);
      expect(comment.replyCount, 0);
      expect(comment.readSeconds, 0);
    });

    test('out-of-range timestamps are dropped instead of throwing', () {
      final raw = <String, dynamic>{
        'text': 'x',
        'create_timestamp': 9223372036854775807,
      };

      expect(() => BookComment.fromRaw(raw), returnsNormally);
      final comment = BookComment.fromRaw(raw);
      expect(comment, isNotNull);
      expect(comment!.createdAt, isNull);
    });

    test('page counters and paragraph stats use the guarded helpers', () {
      final page = parseParagraphComments({
        'code': 0,
        'data': {
          'data_list': [
            {
              'comment': {
                'comment_id': '5',
                'common': {
                  'content': {'text': 'hi'},
                  'create_timestamp': 9223372036854775807,
                  'user_info': {
                    'base_info': {'user_name': 'u'},
                  },
                },
                'stat': {
                  'digg_count': jsonDecode('1e309'),
                  'reply_count': double.infinity,
                },
              },
            },
          ],
        },
      });

      expect(page.comments, hasLength(1));
      expect(page.comments.single.diggCount, 0);
      expect(page.comments.single.replyCount, 0);
      expect(page.comments.single.createdAt, isNull);

      final guarded = BookCommentPage.fromPayload({
        'data': {'comment_cnt': jsonDecode('1e309')},
      });
      expect(guarded.totalCount, 0);
    });
  });

  group('AudioTone numeric guards', () {
    test('non-finite tone_gender degrades to 0 instead of throwing', () {
      expect(
        () => AudioTone.fromRaw(<String, dynamic>{
          'id': '1',
          'title': 'tone',
          'tone_gender': double.infinity,
        }),
        returnsNormally,
      );
      final tone = AudioTone.fromRaw(<String, dynamic>{
        'id': '1',
        'title': 'tone',
        'tone_gender': double.infinity,
      });
      expect(tone, isNotNull);
      expect(tone!.gender, 0);
    });
  });
}
