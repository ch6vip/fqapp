import 'package:flutter_test/flutter_test.dart';

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
  });
}
