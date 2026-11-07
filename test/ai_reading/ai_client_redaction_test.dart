import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/services/ai_reading/ai_client.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';

// Synthetic opaque markers deliberately do not rely on a provider key format.
const _marker = r'opaque-fixture-7Qw9.A$z+[]';
const _rawKey = '\t $_marker \n';

AiProviderProfile _profile() => AiProviderProfile(
  id: 'custom',
  label: 'Custom',
  baseUrl: 'https://example.invalid/v1',
  credentialRef: 'fixture-ref',
  outputMode: AiOutputMode.jsonObject,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Future<AiProviderResponse> _complete(
  AiChatCompletionsClient client, {
  bool stream = false,
  String apiKey = _rawKey,
  String model = 'fixture-model',
}) => client.complete(
  profile: _profile(),
  apiKey: apiKey,
  model: model,
  messages: const [
    {'role': 'user', 'content': 'fixture content'},
  ],
  outputMode: AiOutputMode.jsonObject,
  timeout: const Duration(seconds: 5),
  stream: stream,
);

Future<AiNetworkException> _failure(Future<AiProviderResponse> request) async {
  try {
    await request;
  } on AiNetworkException catch (error) {
    return error;
  }
  throw StateError('Expected AiNetworkException');
}

String _errorBody(String message) => jsonEncode({
  'error': {'message': message},
});

void main() {
  late List<String> logs;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    logs = [];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
  });

  AiChatCompletionsClient clientFor(http.Client transport) {
    addTearDown(transport.close);
    return AiChatCompletionsClient(client: transport);
  }

  for (final stream in [false, true]) {
    for (final status in [401, 429, 503]) {
      test('HTTP $status redacts raw and trimmed key (stream=$stream)', () async {
        var sends = 0;
        final client = clientFor(
          MockClient((request) async {
            sends++;
            expect(request.headers['Authorization'], 'Bearer $_marker');
            return http.Response(
              _errorBody(
                'Provider detail: raw=($_rawKey); trimmed=$_marker; retry later',
              ),
              status,
              headers: {'retry-after': '7'},
            );
          }),
        );
        final error = await _failure(_complete(client, stream: stream));
        expect(
          error.message,
          'Provider detail: raw=([REDACTED]); trimmed=[REDACTED]; retry later',
        );
        expect(error.toString(), error.message);
        expect(error.code, switch (status) {
          401 => 'AUTH_ERROR',
          429 => 'RATE_LIMITED',
          _ => 'SERVER_ERROR',
        });
        expect(error.statusCode, status);
        expect(error.retryAfter, const Duration(seconds: 7));
        expect(error.retryable, status != 401);
        expect(error.usage, isNull);
        expect(sends, 1);
        expect(logs.join('\n'), isNot(contains(_marker)));
      });
    }

    test('redacts key before 300-character cutoff (stream=$stream)', () async {
      final prefix = 'x' * 292;
      final client = clientFor(
        MockClient(
          (_) async => http.Response(
            _errorBody('$prefix$_marker; useful trailing detail'),
            400,
          ),
        ),
      );
      final error = await _failure(_complete(client, stream: stream));
      expect(
        error.message,
        '$prefix[REDACTED]; useful trailing detail'.substring(0, 300),
      );
      expect(error.message, isNot(contains(_marker.substring(0, 8))));
      expect(error.message.length, 300);
      expect(error.code, 'REQUEST_REJECTED');
      expect(error.retryable, isFalse);
    });

    test('top-level HTTP message remains useful (stream=$stream)', () async {
      final client = clientFor(
        MockClient(
          (_) async => http.Response(
            jsonEncode({'message': 'Unsupported model for $_marker'}),
            404,
          ),
        ),
      );
      final error = await _failure(_complete(client, stream: stream));
      expect(error.message, 'Unsupported model for [REDACTED]');
      expect(error.code, 'MODEL_OR_ENDPOINT_NOT_FOUND');
      expect(error.retryable, isFalse);
    });
  }

  test(
    'SSE error event redacts before truncation without changing metadata',
    () async {
      final prefix = 'x' * 292;
      final client = clientFor(
        MockClient(
          (_) async => http.Response(
            'event: error\ndata: ${_errorBody('$prefix$_marker; retry later')}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
      );
      final error = await _failure(_complete(client, stream: true));
      expect(error.message, '$prefix[REDACTED]; retry later'.substring(0, 300));
      expect(error.message, isNot(contains(_marker.substring(0, 8))));
      expect(error.code, 'API_ERROR');
      expect(error.statusCode, isNull);
      expect(error.retryAfter, isNull);
      expect(error.retryable, isFalse);
      expect(error.usage, isNull);
    },
  );

  for (final stream in [false, true]) {
    for (final clientException in [false, true]) {
      for (final stage in ['send', 'body', 'error body']) {
        test(
          'transport echo redacted: stream=$stream clientException=$clientException stage=$stage',
          () async {
            final detail = 'Connection failed raw=($_rawKey); trimmed=$_marker';
            final exception = clientException
                ? http.ClientException(detail)
                : StateError(detail);
            final client = clientFor(
              MockClient.streaming((_, _) async {
                if (stage == 'send') throw exception;
                return http.StreamedResponse(
                  Stream<List<int>>.error(exception),
                  stage == 'error body' ? 429 : 200,
                );
              }),
            );
            final error = await _failure(_complete(client, stream: stream));
            expect(
              error.message,
              contains(
                'Connection failed raw=([REDACTED]); trimmed=[REDACTED]',
              ),
            );
            expect(error.toString(), isNot(contains(_marker)));
            expect(error.code, 'NETWORK_ERROR');
            expect(error.retryable, isTrue);
            expect(error.statusCode, isNull);
            expect(error.retryAfter, isNull);
          },
        );
      }
    }
  }

  test('SSE malformed JSON catch redacts echoed source', () async {
    final client = clientFor(
      MockClient((_) async => http.Response('data: $_marker\n\n', 200)),
    );
    final error = await _failure(_complete(client, stream: true));
    expect(error.code, 'NETWORK_ERROR');
    expect(error.retryable, isTrue);
    expect(error.message, contains('FormatException'));
    expect(error.message, contains('[REDACTED]'));
    expect(error.message, isNot(contains(_marker)));
  });

  test(
    'existing stream exceptions keep all metadata after redaction',
    () async {
      const usage = AiUsage(
        promptTokens: 12,
        completionTokens: 3,
        totalTokens: 15,
      );
      final client = clientFor(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream<List<int>>.error(
              const AiNetworkException(
                'PROVIDER_DETAIL',
                'Provider failed for $_rawKey and $_marker',
                statusCode: 503,
                retryable: true,
                retryAfter: Duration(seconds: 9),
                usage: usage,
              ),
            ),
            200,
          ),
        ),
      );
      final error = await _failure(_complete(client, stream: true));
      expect(error.message, 'Provider failed for [REDACTED] and [REDACTED]');
      expect(error.code, 'PROVIDER_DETAIL');
      expect(error.statusCode, 503);
      expect(error.retryable, isTrue);
      expect(error.retryAfter, const Duration(seconds: 9));
      expect(error.usage, same(usage));
    },
  );

  test(
    'refusal message keeps useful text without exposing either key form',
    () async {
      final client = clientFor(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'refusal':
                        'Cannot process raw=($_rawKey); trimmed=$_marker',
                  },
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          ),
        ),
      );
      final error = await _failure(_complete(client));
      expect(
        error.message,
        '模型拒绝了本次请求：Cannot process raw=([REDACTED]); trimmed=[REDACTED]',
      );
      expect(error.code, 'REFUSAL');
      expect(error.retryable, isFalse);
      expect(error.statusCode, isNull);
      expect(error.retryAfter, isNull);
      expect(error.usage, isNull);
    },
  );

  test(
    'truncated response never logs returned content and keeps usage',
    () async {
      const returnedContent = 'private-returned-content $_rawKey $_marker';
      final client = clientFor(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': returnedContent},
                  'finish_reason': 'length',
                },
              ],
              'usage': {
                'prompt_tokens': 12,
                'completion_tokens': 3,
                'total_tokens': 15,
              },
            }),
            200,
          ),
        ),
      );
      final error = await _failure(_complete(client));
      expect(error.code, 'FINISH_REASON_LENGTH');
      expect(error.retryable, isFalse);
      expect(error.usage?.promptTokens, 12);
      expect(error.usage?.completionTokens, 3);
      expect(error.usage?.totalTokens, 15);
      expect(logs.join('\n'), contains('usage=12/3/15'));
      expect(logs.join('\n'), isNot(contains('private-returned-content')));
      expect(logs.join('\n'), isNot(contains(_marker)));
    },
  );

  for (final stream in [false, true]) {
    test(
      'diagnostic metadata redacted but success content unchanged (stream=$stream)',
      () async {
        final client = clientFor(
          MockClient((_) async {
            final choice = {
              stream ? 'delta' : 'message': {'content': 'Result $_marker'},
              'finish_reason': _marker,
            };
            final body = jsonEncode({
              'choices': [choice],
            });
            return http.Response(
              stream ? 'data: $body\n\ndata: [DONE]\n\n' : body,
              200,
            );
          }),
        );
        final response = await _complete(
          client,
          stream: stream,
          model: _marker,
        );
        expect(response.content, 'Result $_marker');
        expect(response.finishReason, _marker);
        expect(logs, isNotEmpty);
        expect(logs.join('\n'), contains('model=[REDACTED]'));
        expect(logs.join('\n'), contains('finish=[REDACTED]'));
        expect(logs.join('\n'), isNot(contains(_marker)));
      },
    );
  }

  test('concurrent requests keep separate redaction keys', () async {
    const secondMarker = 'opaque-fixture-B6v2';
    final firstSeen = Completer<void>();
    final secondSeen = Completer<void>();
    final releaseFirst = Completer<void>();
    final releaseSecond = Completer<void>();
    final client = clientFor(
      MockClient((request) async {
        final first = request.headers['Authorization'] == 'Bearer $_marker';
        (first ? firstSeen : secondSeen).complete();
        await (first ? releaseFirst : releaseSecond).future;
        final marker = first ? _marker : secondMarker;
        final body = _errorBody(
          '${first ? 'First' : 'Second'} request: $marker',
        );
        return http.Response(
          first ? body : 'data: $body\n\n',
          first ? 429 : 200,
        );
      }),
    );
    final first = _failure(_complete(client));
    await firstSeen.future;
    final second = _failure(
      _complete(client, stream: true, apiKey: ' $secondMarker '),
    );
    await secondSeen.future;
    releaseFirst.complete();
    final firstError = await first;
    releaseSecond.complete();
    final secondError = await second;
    expect(firstError.message, 'First request: [REDACTED]');
    expect(secondError.message, 'Second request: [REDACTED]');
  });

  test('probe returns a sanitized failure detail for persistence', () async {
    final client = clientFor(
      MockClient(
        (_) async => http.Response(
          _errorBody('Invalid credential $_rawKey / $_marker'),
          401,
        ),
      ),
    );
    final capability = await client.probe(
      profile: _profile(),
      apiKey: _rawKey,
      model: 'fixture-model',
      outputMode: AiOutputMode.jsonObject,
      timeout: const Duration(seconds: 5),
    );
    expect(capability.ok, isFalse);
    expect(capability.detail, 'Invalid credential [REDACTED] / [REDACTED]');
  });
}
