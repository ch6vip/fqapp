import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const special = 'id &mode=changed#+/中文%';

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
