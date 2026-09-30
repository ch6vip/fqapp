import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'series detail strict failures preserve legacy best-effort callers',
    () async {
      for (final response in [
        http.Response('offline', 503),
        http.Response('{"code":0,"data":{}}', 200),
        http.Response('{"code":500,"message":"unavailable"}', 200),
      ]) {
        final transport = MockClient((_) async => response);
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          baseUrl: 'http://localhost:9000',
        );
        expect((await api.seriesDetail('s1')).isEmpty, isTrue);
        await expectLater(
          api.seriesDetail('s1', strict: true),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );

  const special = 'id &mode=changed#+/中文%';

  group('paragraph comments from saved catalogues', () {
    for (final savedVersion in ['', 'saved-version']) {
      test(
        'resolves only missing versions before loading comments ($savedVersion)',
        () async {
          final requests = <Uri>[];
          final transport = MockClient((request) async {
            requests.add(request.url);
            final payload = request.url.path == '/api/directory'
                ? {
                    'code': 200,
                    'data': {
                      'item_data_list': [
                        {
                          'item_id': 'other',
                          'title': '第一章',
                          'version': 'other-version',
                        },
                        {
                          'item_id': 'chapter',
                          'title': '第二章',
                          'version': 'fresh-version',
                        },
                      ],
                    },
                  }
                : {
                    'code': 0,
                    'data': {
                      'common_list_info': {'total': 522},
                      'data_list': [
                        {
                          'comment': {
                            'comment_id': 'c1',
                            'common': {
                              'content': {'text': '实际段评'},
                            },
                          },
                        },
                      ],
                    },
                  };
            return http.Response.bytes(utf8.encode(jsonEncode(payload)), 200);
          });
          addTearDown(transport.close);
          final api = ApiClient(
            client: transport,
            baseUrl: 'http://localhost:9000',
          );
          final page = await api.paragraphComments(
            'book',
            'chapter',
            itemVersion: savedVersion,
            paraIndex: 4,
          );
          expect(requests.length, savedVersion.isEmpty ? 2 : 1);
          expect(
            requests.last.queryParameters['item_version'],
            savedVersion.isEmpty ? 'fresh-version' : savedVersion,
          );
          expect(requests.last.queryParameters['group_id'], 'chapter');
          expect(requests.last.queryParameters['para_index'], '4');
          // 38 is the paragraph-comment channel that matches the idea count
          // on every tested book; 43/39 are empty or partial.
          expect(requests.last.queryParameters['server_channel'], '38');
          // The first page sends no cursor: the request must stay byte for
          // byte identical with the verified recipe.
          expect(requests.last.queryParameters.containsKey('cursor'), isFalse);
          expect(page.totalCount, 522);
          expect(page.comments.single.text, '实际段评');
        },
      );
    }

    test(
      'a missing chapter version is retryable failure, not an empty list',
      () async {
        final requests = <Uri>[];
        final transport = MockClient((request) async {
          requests.add(request.url);
          return http.Response('{"code":200,"data":{}}', 200);
        });
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          baseUrl: 'http://localhost:9000',
        );
        await expectLater(
          api.paragraphComments(
            'book',
            'missing',
            itemVersion: '',
            paraIndex: 0,
          ),
          throwsA(isA<ApiException>()),
        );
        expect(requests.single.path, '/api/directory');
      },
    );

    test('the cursor token is forwarded so the panel can page', () async {
      final requests = <Uri>[];
      final transport = MockClient((request) async {
        requests.add(request.url);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'common_list_info': {
                  'total': 522,
                  'has_more': false,
                  'cursor': '40',
                },
                'data_list': [
                  {
                    'comment': {
                      'comment_id': 'c2',
                      'common': {
                        'content': {'text': '第二页的段评'},
                      },
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
      final api = ApiClient(
        client: transport,
        baseUrl: 'http://localhost:9000',
      );
      final page = await api.paragraphComments(
        'book',
        'chapter',
        itemVersion: 'v',
        paraIndex: 0,
        cursor: '20',
      );
      expect(requests.single.queryParameters['cursor'], '20');
      expect(page.comments.single.text, '第二页的段评');
      expect(page.hasMore, isFalse);
      expect(page.nextOffset, 40);
    });
  });

  for (final wrapped in [false, true]) {
    test(
      'typed search isolates its source before splitting manju ($wrapped)',
      () async {
        late Uri sent;
        final payload = {
          'code': 0,
          'search_tabs': [
            {
              'title': '综合',
              'tab_type': 1,
              'has_more': true,
              'next_offset': 99,
              'data': [
                {'video_id': 'other', 'title': '其他栏目的漫剧', 'kind': 'manju'},
              ],
            },
            {
              'title': '短剧',
              'tab_type': '11',
              'has_more': true,
              'next_offset': '27',
              'data': [
                {'video_id': 'live', 'title': '本栏短剧'},
                {'video_id': 'animated', 'title': '本栏漫剧', 'kind': 'manju'},
              ],
            },
          ],
        };
        final transport = MockClient((request) async {
          sent = request.url;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(wrapped ? {'code': 200, 'data': payload} : payload),
            ),
            200,
          );
        });
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          baseUrl: 'http://localhost:9000',
        );

        final tabs = await api.searchTabs('作品', tabType: 11, offset: 14);
        expect(sent.path, '/api/v1/search');
        expect(sent.queryParameters, {
          'query': '作品',
          'tab_type': '11',
          'offset': '14',
          'count': '10',
        });
        expect(tabs.map((tab) => tab.title), ['短剧', '漫剧']);
        expect(tabs[0].items.single.id, 'live');
        expect(tabs[1].items.single.id, 'animated');
        expect(
          tabs.every((tab) => tab.hasMore == true && tab.nextOffset == 27),
          isTrue,
        );
      },
    );
  }

  test('query values survive all API request builders unchanged', () async {
    late Uri sent;
    final transport = MockClient((request) async {
      sent = request.url;
      return http.Response('{"code":200,"data":{}}', 200);
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');

    await api.search(special, page: 2);
    expect(sent.queryParameters, {
      'source': '番茄',
      'query': special,
      'page': '2',
    });
    await api.searchTabs(special, page: 3);
    expect(sent.queryParameters['query'], special);
    await api.searchTabs(special, page: 3, tabType: 8);
    expect(sent.path, '/api/v1/search');
    expect(sent.queryParameters, {
      'query': special,
      'tab_type': '8',
      'offset': '20',
      'count': '10',
    });
    expect(sent.fragment, isEmpty);

    await api.searchTabs(special, page: 3, tabType: 11, offset: 17);
    expect(sent.path, '/api/v1/search');
    expect(sent.queryParameters, {
      'query': special,
      'tab_type': '11',
      'offset': '17',
      'count': '10',
    });

    for (final action in [api.detail, api.directory, api.directoryChapters]) {
      await action(special, tab: special);
      expect(sent.queryParameters, {
        'source': '番茄',
        'book_id': special,
        'tab': special,
      });
      expect(sent.fragment, isEmpty);
    }

    await api.content(special, tab: special, toneId: special, mode: special);
    expect(sent.queryParameters, {
      'source': '番茄',
      'item_id': special,
      'tab': special,
      'tone_id': special,
      'mode': special,
    });
    await api.contentText(special, tab: special);
    expect(sent.queryParameters['item_id'], special);
    expect(sent.fragment, isEmpty);

    await api.resolve(special);
    expect(sent.queryParameters, {'url': special});
    await api.homepageRecommend(tabType: 8, offset: 2, sessionId: special);
    expect(sent.queryParameters, {
      'tab_type': '8',
      'offset': '2',
      'session_id': special,
    });
    await api.homepagePage(tabType: 8, offset: 2, sessionId: special);
    expect(sent.queryParameters['session_id'], special);
    expect(sent.fragment, isEmpty);
  });

  test('resource URLs resolve network paths and backend paths correctly', () {
    final transport = MockClient((_) async => http.Response('', 200));
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');

    expect(api.absoluteUrl('  '), isEmpty);
    expect(
      api.absoluteUrl('/src/video.mp4'),
      'http://localhost:9000/src/video.mp4',
    );
    expect(
      api.absoluteUrl('src/video.mp4'),
      'http://localhost:9000/src/video.mp4',
    );
    expect(
      api.absoluteUrl('//cdn.example/video.mp4'),
      'http://cdn.example/video.mp4',
    );
    const signed = 'https://cdn.example/video.mp4?sign=a%2Fb+xyz';
    expect(api.absoluteUrl(' $signed '), signed);
  });

  test(
    'both supported envelopes preserve UTF-8 data through parsing',
    () async {
      for (final code in [0, 200]) {
        final transport = MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'code': code,
                'data': {
                  'search_tabs': [
                    {
                      'title': '小说',
                      'data': [
                        {'book_id': '1', 'book_name': '中文书名'},
                      ],
                    },
                  ],
                },
              }),
            ),
            200,
          ),
        );
        addTearDown(transport.close);
        final tabs = await ApiClient(client: transport).searchTabs('中文');
        expect(tabs.single.items.single.title, '中文书名');
      }
    },
  );

  test('unsuccessful envelopes surface as API errors', () async {
    for (final body in [
      {'code': 500, 'message': '失败'},
      {'success': false, 'error': '失败'},
    ]) {
      final transport = MockClient(
        (_) async => http.Response.bytes(utf8.encode(jsonEncode(body)), 200),
      );
      addTearDown(transport.close);
      await expectLater(
        ApiClient(client: transport).detail('1'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', '失败')),
      );
    }
  });

  for (final stallsBody in [false, true]) {
    test(
      'timeout aborts stalled ${stallsBody ? 'body' : 'headers'} only',
      () async {
        final transport = _AbortAwareClient(stallsBody: stallsBody);
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          timeout: const Duration(milliseconds: 20),
        );

        await expectLater(
          api.detail('stalled'),
          throwsA(isA<TimeoutException>()),
        );
        await transport.aborted.future.timeout(const Duration(seconds: 1));
        expect(await api.search('healthy'), {'code': 200});
      },
    );
  }
}

class _AbortAwareClient extends http.BaseClient {
  _AbortAwareClient({required this.stallsBody});

  final bool stallsBody;
  final aborted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path != '/api/detail') {
      return Future.value(
        http.StreamedResponse(Stream.value(utf8.encode('{"code":200}')), 200),
      );
    }
    final pending = Completer<http.StreamedResponse>();
    final body = StreamController<List<int>>();
    if (stallsBody) pending.complete(http.StreamedResponse(body.stream, 200));
    (request as http.AbortableRequest).abortTrigger!.then((_) {
      aborted.complete();
      final error = http.RequestAbortedException(request.url);
      if (stallsBody) {
        body.addError(error);
        body.close().ignore();
      } else {
        pending.completeError(error);
        body.close().ignore();
      }
    });
    return pending.future;
  }
}
