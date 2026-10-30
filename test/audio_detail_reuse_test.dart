import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const base = 'http://localhost:9000';

  http.Response envelope(Object data) => http.Response.bytes(
    utf8.encode(jsonEncode({'code': 200, 'data': data})),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  test('opening a listening session requests book detail once', () async {
    final sent = <Uri>[];
    final transport = MockClient((request) async {
      sent.add(request.url);
      return envelope({'book_id': 'book', 'book_name': '书名', 'tones': '2, 3'});
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: base);

    final voices = await api.audioVoices('book');
    expect(voices.map((voice) => voice.id), ['0', '2', '3']);

    final detail = await api.bookDetail('book');
    expect(detail.title, '书名');
    expect(sent, hasLength(1), reason: 'voices and metadata share one detail');

    // The payload is a one-shot handoff, not a cache: a later refresh
    // (version switch, page reopen) must fetch again.
    await api.bookDetail('book');
    expect(sent, hasLength(2));
  });

  test('a detail handoff is never reused for another book', () async {
    final sent = <Uri>[];
    final transport = MockClient((request) async {
      sent.add(request.url);
      final id = request.url.pathSegments[3];
      return envelope({'book_id': id, 'book_name': '书名 $id', 'tones': '2'});
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: base);

    await api.audioVoices('first');
    final other = await api.bookDetail('second');
    expect(other.title, '书名 second');
    expect(sent, hasLength(2));
  });
}
