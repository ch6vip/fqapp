import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

void main() {
  group('absoluteUrl scheme allowlist', () {
    late http.Client transport;
    late ApiClient api;

    setUp(() {
      transport = MockClient((_) async => http.Response('', 200));
      api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');
    });

    tearDown(() {
      transport.close();
    });

    test('drops absolute non-http(s) schemes and empty hosts', () {
      expect(api.absoluteUrl('file:///data/secret.mp4'), isEmpty);
      expect(api.absoluteUrl('content://com.example/secret'), isEmpty);
      expect(api.absoluteUrl('javascript:alert(1)'), isEmpty);
      expect(api.absoluteUrl('data:text/plain,hi'), isEmpty);
      expect(api.absoluteUrl('https://'), isEmpty);
      expect(api.absoluteUrl('http:relative'), isEmpty);
    });

    test('keeps http(s), backend-relative and protocol-relative URLs', () {
      expect(
        api.absoluteUrl(' /src/video.mp4 '),
        'http://localhost:9000/src/video.mp4',
      );
      expect(
        api.absoluteUrl('//cdn.example/video.mp4'),
        'http://cdn.example/video.mp4',
      );
      const signed = 'https://cdn.example/video.mp4?sign=a%2Fb+xyz';
      expect(api.absoluteUrl(' $signed '), signed);
    });
  });

  group('EpisodeSource.fromResponse scheme validation', () {
    test('rejects local file and content URIs', () {
      for (final rawUrl in [
        'file:///data/user/0/com.fqapp.fqapp/files/secret.mp4',
        'content://com.example/secret',
      ]) {
        expect(
          () => EpisodeSource.fromResponse({
            'data': {'video_url': rawUrl},
          }),
          throwsA(isA<ApiException>()),
        );
      }
    });

    test('keeps a valid https source and its key', () {
      final source = EpisodeSource.fromResponse({
        'data': {
          'video_url': ' https://cdn.example/a.mp4 ',
          'key_hex': ' 1234 ',
        },
      });
      expect(source.url, 'https://cdn.example/a.mp4');
      expect(source.keyHex, '1234');
    });
  });

  group('non-200 response bodies', () {
    test('surface the backend error message', () async {
      final transport = MockClient(
        (_) async => _json({'code': 400, 'message': '需要 url'}, status: 400),
      );
      addTearDown(transport.close);
      final api = ApiClient(
        client: transport,
        baseUrl: 'http://localhost:9000',
      );
      await expectLater(
        api.resolve(''),
        throwsA(
          isA<ApiException>()
              .having((error) => error.message, 'message', '需要 url')
              .having((error) => error.statusCode, 'statusCode', 400),
        ),
      );
    });

    test('fall back to the status when the body is not an envelope', () async {
      final transport = MockClient((_) async => http.Response('not json', 500));
      addTearDown(transport.close);
      final api = ApiClient(
        client: transport,
        baseUrl: 'http://localhost:9000',
      );
      await expectLater(
        api.resolve('x'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            'HTTP 500',
          ),
        ),
      );
    });
  });

  group('player page rejects non-http(s) sources', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('fqapp/native_player'),
            (call) async => null,
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('fqapp/native_player'),
            null,
          );
    });

    testWidgets('does not create a player for a local-file source', (
      tester,
    ) async {
      final player = ControlledNativePlayer();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            bookId: 'book',
            title: '测试',
            eps: [Chapter(itemId: '1', title: '第 1 集', volumeName: '')],
            startIndex: 0,
            contentLoader: (_) async => {
              'video_url':
                  'file:///data/user/0/com.fqapp.fqapp/files/secret.mp4',
            },
            playerFactory: () => player,
          ),
        ),
      );
      await _flush(tester);
      expect(player.calls.where((call) => call.startsWith('create:')), isEmpty);
      expect(find.byKey(const ValueKey('player-error')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
    });
  });
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

http.Response _json(Object payload, {int status = 200}) => http.Response(
  jsonEncode(payload),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
