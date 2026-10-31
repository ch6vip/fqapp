import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/api_response_decoder.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final originalRunner = decodeIsolateRunner;

  setUp(() => decodeIsolateRunner = originalRunner);
  tearDown(() => decodeIsolateRunner = originalRunner);

  test(
    'envelope bodies at the inline limit stay on the calling isolate',
    () async {
      var isolateRuns = 0;
      decodeIsolateRunner = <T>(FutureOr<T> Function() computation) {
        isolateRuns++;
        return Future<T>.value(computation());
      };

      expect(
        await decodeResponseBody(inlineDecodeLimit, () => 'inline'),
        'inline',
      );
      expect(isolateRuns, 0);

      expect(
        await decodeResponseBody(inlineDecodeLimit + 1, () => 'isolate'),
        'isolate',
      );
      expect(isolateRuns, 1);
    },
  );

  test('ApiClient decodes small detail payloads inline', () async {
    var isolateRuns = 0;
    decodeIsolateRunner = <T>(FutureOr<T> Function() computation) {
      isolateRuns++;
      return Isolate.run(computation);
    };
    final transport = MockClient((request) async {
      final id = request.url.pathSegments[3];
      final body = id == 'large'
          ? 'x' * inlineDecodeLimit
          : '{"book_name":"书名"}';
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'code': 200,
            'data': {'book_id': id, 'abstract': body},
          }),
        ),
        200,
      );
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');

    final small = await api.detail('small');
    expect(small['data'], {
      'book_id': 'small',
      'abstract': '{"book_name":"书名"}',
    });
    expect(
      isolateRuns,
      0,
      reason: 'a small response must not pay for an isolate spawn',
    );

    final large = await api.detail('large');
    expect((large['data'] as Map)['abstract'], hasLength(inlineDecodeLimit));
    expect(
      isolateRuns,
      1,
      reason: 'a large response must decode off the calling isolate',
    );
  });
}
