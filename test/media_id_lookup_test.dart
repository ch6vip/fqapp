import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const id = '7677801492920667198';
  const metadata = {
    'book_id': id,
    'book_name': '漫剧作品',
    'genre': '205',
    'genre_type': '2150',
  };
  http.Response json(Object payload, [int status = 200]) =>
      http.Response.bytes(utf8.encode(jsonEncode(payload)), status);

  test(
    'ID lookup calls exact detail path and skips fallback on success',
    () async {
      final requests = <Uri>[];
      final transport = MockClient((request) async {
        requests.add(request.url);
        return json({'code': 0, 'data': metadata});
      });
      addTearDown(transport.close);
      final api = ApiClient(
        client: transport,
        baseUrl: 'http://localhost:9000',
      );
      final item = (await api.lookupMediaById(id))!;
      expect(requests.single.path, '/api/v1/books/$id/detail');
      expect(requests.single.queryParameters, isEmpty);
      expect(item.id, id);
      expect(item.seriesId, id);
      expect(item.kind, 'manju');
    },
  );

  for (final unavailable in ['http404', 'empty', 'error']) {
    test(
      'directory book_info resolves an ID after $unavailable detail',
      () async {
        final paths = <String>[];
        final transport = MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/detail')) {
            return switch (unavailable) {
              'http404' => json({}, 404),
              'empty' => json({'code': 0, 'data': {}}),
              _ => json({}, 500),
            };
          }
          return json({
            'code': 0,
            'data': {'book_info': metadata},
          });
        });
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          baseUrl: 'http://localhost:9000',
        );
        final item = await api.lookupMediaById(id);
        expect(item?.id, id);
        expect(paths, [
          '/api/v1/books/$id/detail',
          '/api/v1/books/$id/directory',
        ]);
      },
    );
  }

  test(
    'an explicitly missing ID returns no result without requesting a directory',
    () async {
      var calls = 0;
      final transport = MockClient((_) async {
        calls++;
        return json({
          'code': 101104,
          'message': 'BOOK_NOT_EXIST_ERROR',
          'data': {},
        });
      });
      addTearDown(transport.close);
      final api = ApiClient(
        client: transport,
        baseUrl: 'http://localhost:9000',
      );
      expect(await api.lookupMediaById(id), isNull);
      expect(calls, 1);
    },
  );

  test('mismatched responses cannot become a fake exact ID match', () async {
    final transport = MockClient(
      (_) async => json({
        'code': 0,
        'data': {'book_id': 'other', 'book_name': '其他作品'},
      }),
    );
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');
    expect(await api.lookupMediaById(id), isNull);
  });

  test(
    'transport failure stays retryable even if fallback has no record',
    () async {
      final transport = MockClient(
        (request) async => request.url.path.endsWith('/detail')
            ? json({}, 503)
            : json({'code': 101104, 'message': 'BOOK_NOT_EXIST_ERROR'}),
      );
      addTearDown(transport.close);
      final api = ApiClient(
        client: transport,
        baseUrl: 'http://localhost:9000',
      );
      await expectLater(
        api.lookupMediaById(id),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            503,
          ),
        ),
      );
    },
  );

  test('invalid IDs are rejected before making a request', () async {
    var calls = 0;
    final transport = MockClient((_) async {
      calls++;
      return json({});
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');
    for (final invalid in [
      '',
      '0',
      '-1',
      '12?other=1',
      '123456789012345678901',
    ]) {
      await expectLater(
        api.lookupMediaById(invalid),
        throwsA(isA<ApiException>()),
      );
    }
    expect(calls, 0);
  });
}
