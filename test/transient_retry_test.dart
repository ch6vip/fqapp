import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/transient_retry.dart';

void main() {
  group('retryTransient', () {
    test('returns the first successful result without retrying', () async {
      var calls = 0;
      final result = await retryTransient(() async {
        calls++;
        return 'ok';
      });
      expect(result, 'ok');
      expect(calls, 1);
    });

    test('retries a transient failure and returns the later success', () async {
      var calls = 0;
      final result = await retryTransient(() async {
        calls++;
        // Mirrors the body-level "invalid aid" the backend can return.
        if (calls < 3) throw StateError('invalid aid');
        return calls;
      }, baseDelay: Duration.zero);
      expect(result, 3);
      expect(calls, 3);
    });

    test('rethrows the last error after exhausting the attempts', () async {
      var calls = 0;
      await expectLater(
        retryTransient<int>(
          () async {
            calls++;
            throw StateError('invalid aid $calls');
          },
          attempts: 4,
          baseDelay: Duration.zero,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'invalid aid 4',
          ),
        ),
      );
      expect(calls, 4);
    });

    test('rejects a non-positive attempt count', () async {
      await expectLater(
        retryTransient<int>(() async => 1, attempts: 0),
        throwsArgumentError,
      );
    });

    test('a failing shouldRetry stops after the first attempt', () async {
      var calls = 0;
      await expectLater(
        retryTransient<int>(
          () async {
            calls++;
            throw StateError('deterministic');
          },
          shouldRetry: (_) => false,
          baseDelay: Duration.zero,
        ),
        throwsStateError,
      );
      expect(calls, 1);
    });
  });

  group('isTransientNetworkFailure', () {
    test('only network breaks, 408/429 and 5xx are retried', () {
      expect(isTransientNetworkFailure(const SocketException('reset')), isTrue);
      expect(
        isTransientNetworkFailure(http.ClientException('connection closed')),
        isTrue,
      );
      expect(
        isTransientNetworkFailure(const HttpException('premature end')),
        isTrue,
      );
      for (final status in [408, 429, 500, 502, 503]) {
        expect(
          isTransientNetworkFailure(
            ApiException('HTTP $status', statusCode: status),
          ),
          isTrue,
          reason: 'HTTP $status 是瞬时失败',
        );
      }
    });

    test('timeouts, other statuses and business codes fail fast', () {
      expect(
        isTransientNetworkFailure(TimeoutException('30s deadline')),
        isFalse,
        reason: '单次尝试已经等满期限，再试只会让用户多等三倍',
      );
      for (final status in [400, 401, 403, 404, 410, 416]) {
        expect(
          isTransientNetworkFailure(
            ApiException('HTTP $status', statusCode: status),
          ),
          isFalse,
        );
      }
      expect(
        isTransientNetworkFailure(
          const ApiException('NO_THIS_TONE', upstreamCode: 101000),
        ),
        isFalse,
        reason: '业务错误码每次都是同一个结果',
      );
      expect(isTransientNetworkFailure(const ApiException('本章正在审核中')), isFalse);
      expect(
        isTransientNetworkFailure(const FormatException('bad body')),
        isFalse,
      );
    });

    test('a timeout is not multiplied by the audio-source policy', () async {
      var calls = 0;
      await expectLater(
        retryTransient<int>(
          () async {
            calls++;
            throw TimeoutException('音源请求超时');
          },
          shouldRetry: isTransientNetworkFailure,
          baseDelay: Duration.zero,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls, 1);
    });
  });
}
