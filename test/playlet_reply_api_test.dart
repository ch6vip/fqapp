import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'anonymous replies preserve ids, pagination and upstream errors',
    () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        if (requests.length == 3) {
          return http.Response('{"error":"unavailable"}', 503);
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'common_list_info': {
                  'total': 2,
                  'cursor': 'next&cursor',
                  'has_more': true,
                },
                'reply_list': [
                  {
                    'reply_id': 'r1',
                    'common': {
                      'content': {'text': '匿名回复'},
                    },
                  },
                ],
              },
            }),
          ),
          200,
        );
      });
      addTearDown(transport.close);
      final api = ApiClient(client: transport);
      final page = await api.playletCommentReplies('剧集/1', 'c&9');
      expect(page.replies.single.text, '匿名回复');
      expect(page.cursor, 'next&cursor');
      expect(page.totalCount, 2);
      expect(page.hasMore, isTrue);
      final uri = requests.first.url;
      expect(requests.first.method, 'GET');
      expect(uri.pathSegments, [
        'api',
        'v1',
        'series',
        '剧集/1',
        'comments',
        'c&9',
        'replies',
      ]);
      expect(uri.queryParameters['count'], '10');
      await api.playletCommentReplies('剧集/1', 'c&9', cursor: page.cursor);
      expect(requests.last.url.queryParameters['cursor'], 'next&cursor');
      expect(
        requests.last.url.queryParameters.containsKey('insert_reply_ids'),
        isFalse,
      );
      await expectLater(
        api.playletCommentReplies('剧集/1', 'c&9', cursor: 'fail'),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
