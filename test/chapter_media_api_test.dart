import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/audio_play_fixture.dart';

void main() {
  const base = 'http://localhost:9000';
  const special = 'id &mode=changed#+/中文%';

  test(
    'book-backed audio goes directly to playback with default tone zero',
    () async {
      final sent = <Uri>[];
      final transport = MockClient((request) async {
        sent.add(request.url);
        return _json(audioPlayFixture(itemId: special));
      });
      addTearDown(transport.close);
      final api = ApiClient(client: transport, baseUrl: base);
      final source = await api.audioSource(special, bookId: special);
      expect(sent.single.path, '/api/v1/audio/play');
      expect(sent.single.queryParameters, {
        'book_id': special,
        'item_ids': special,
        'tone_id': '0',
      });
      expect(source.itemId, special);
      expect(source.toneId, '0');
      expect(source.duration, const Duration(milliseconds: 664741));
      final alternate = await api.audioSource(
        special,
        bookId: special,
        toneId: '2',
      );
      expect(sent.last.queryParameters['tone_id'], '2');
      expect(alternate.toneId, '2');
      expect(sent.map((uri) => uri.path), [
        '/api/v1/audio/play',
        '/api/v1/audio/play',
      ]);
    },
  );

  test(
    'playback business failures are not hidden by outer code zero',
    () async {
      final transport = MockClient(
        (_) async => _json({
          'code': 0,
          'message': 'success',
          'video_info': {'code': 403, 'message': 'invalid aid'},
        }),
      );
      addTearDown(transport.close);
      await expectLater(
        ApiClient(
          client: transport,
          baseUrl: base,
        ).audioSource('chapter', bookId: 'book'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            'invalid aid',
          ),
        ),
      );
    },
  );

  test('audio API requires a book ID instead of the speech bridge', () async {
    final transport = MockClient((request) async {
      fail('audioSource must not issue a request without a book ID');
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: base);
    await expectLater(
      api.audioSource(special),
      throwsA(
        isA<ArgumentError>().having((error) => error.name, 'name', 'bookId'),
      ),
    );
  });

  test(
    'voice API reads ordinary book detail and deduplicates its CSV',
    () async {
      late Uri sent;
      final transport = MockClient((request) async {
        sent = request.url;
        return _json({
          'code': 200,
          'data': {'tones': '2, 3,2, 1'},
        });
      });
      addTearDown(transport.close);

      final voices = await ApiClient(
        client: transport,
        baseUrl: base,
      ).audioVoices(special);
      expect(sent.path, '/api/detail');
      expect(sent.queryParameters, {
        'source': '番茄',
        'book_id': special,
        'tab': '小说',
      });
      expect(voices.map((voice) => voice.id), ['0', '2', '3', '1']);
    },
  );

  test('optional voices fall back on HTTP, JSON, and nested errors', () async {
    for (final response in [
      _json({'message': '网络错误'}, status: 500),
      http.Response('not json', 200),
      _json({'code': 200, 'data': null}),
      _json({
        'code': 200,
        'data': {'code': 101000, 'message': '无音色数据', 'tones': '2,3'},
      }),
    ]) {
      final transport = MockClient((_) async => response);
      addTearDown(transport.close);
      final voices = await ApiClient(
        client: transport,
        baseUrl: base,
      ).audioVoices('book');
      expect(voices.single.id, '0');
      expect(voices.single.label, '默认音色');
    }

    final transport = MockClient((_) async => throw http.ClientException('离线'));
    addTearDown(transport.close);
    final voices = await ApiClient(
      client: transport,
      baseUrl: base,
    ).audioVoices('book');
    expect(voices.single.id, '0');
  });

  test(
    'comic API returns ordered absolute URLs from the manga bridge',
    () async {
      late Uri sent;
      final transport = MockClient((request) async {
        sent = request.url;
        return _json({
          'code': 200,
          'data': {
            'images': ['/src/b.jpg', 'https://cdn.example/a.jpg', '/src/b.jpg'],
          },
        });
      });
      addTearDown(transport.close);
      final images = await ApiClient(
        client: transport,
        baseUrl: base,
      ).comicImages(special);
      expect(sent.path, '/api/content');
      expect(sent.queryParameters, {
        'source': '番茄',
        'item_id': special,
        'tab': '漫画',
      });
      expect(images.map((image) => image.url), [
        '$base/src/b.jpg',
        'https://cdn.example/a.jpg',
        '$base/src/b.jpg',
      ]);
    },
  );

  test('comic API parses the backend content HTML fallback', () async {
    final transport = MockClient(
      (_) async => _json({
        'code': 200,
        'data': {'content': '<img src="/src/page.webp?x=1&amp;y=2">'},
      }),
    );
    addTearDown(transport.close);
    final pages = await ApiClient(
      client: transport,
      baseUrl: base,
    ).comicImages('chapter');
    expect(pages.single.url, '$base/src/page.webp?x=1&y=2');
  });

  test('typed media APIs surface nested upstream business messages', () async {
    final transport = MockClient(
      (_) async => _json({
        'code': 200,
        'data': {
          'code': 101000,
          'message': '章节暂不可用',
          'audio_url': 'https://cdn.example/audio.mp3',
          'images': ['/src/page.jpg'],
        },
      }),
    );
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: base);
    final expected = throwsA(
      isA<ApiException>().having((error) => error.message, 'message', '章节暂不可用'),
    );
    await expectLater(api.audioSource('chapter', bookId: 'book'), expected);
    await expectLater(api.comicImages('chapter'), expected);
  });

  test(
    'typed media APIs reject empty content rather than reporting success',
    () async {
      final transport = MockClient(
        (_) async => _json({
          'code': 200,
          'data': {'images': [], 'audio_url': ''},
        }),
      );
      addTearDown(transport.close);
      final api = ApiClient(client: transport, baseUrl: base);
      await expectLater(
        api.audioSource('chapter', bookId: 'book'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '未获取到音频地址'),
        ),
      );
      await expectLater(
        api.comicImages('chapter'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '未获取到漫画图片'),
        ),
      );
    },
  );

  test('comic fetch can outlast the ordinary API timeout', () async {
    final transport = MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      return _json({
        'code': 200,
        'data': {
          'images': ['/src/page.jpg'],
        },
      });
    });
    addTearDown(transport.close);
    final api = ApiClient(
      client: transport,
      baseUrl: base,
      timeout: const Duration(milliseconds: 20),
      comicTimeout: const Duration(milliseconds: 250),
    );
    expect((await api.comicImages('chapter')).single.url, '$base/src/page.jpg');
  });

  for (final stallsBody in [false, true]) {
    test(
      'comic timeout aborts stalled ${stallsBody ? 'body' : 'headers'} and keeps the client usable',
      () async {
        final transport = _AbortAwareMediaClient(stallsBody: stallsBody);
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          baseUrl: base,
          comicTimeout: const Duration(milliseconds: 20),
        );
        await expectLater(
          api.comicImages('stalled'),
          throwsA(isA<TimeoutException>()),
        );
        await transport.aborted.future.timeout(const Duration(seconds: 1));
        expect(await api.search('healthy'), {'code': 200});
      },
    );
  }
}

http.Response _json(Object? body, {int status = 200}) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

class _AbortAwareMediaClient extends http.BaseClient {
  _AbortAwareMediaClient({required this.stallsBody});

  final bool stallsBody;
  final aborted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.queryParameters['item_id'] != 'stalled') {
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
