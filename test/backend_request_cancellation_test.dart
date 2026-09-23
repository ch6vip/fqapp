import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// F4 regressions: cancellation must travel from the request owner down to the
/// transport, and a cancelled call must never publish its late result.

/// A transport that records the cancellation handle it was given.
class _RecordingTransport implements BackendTransport {
  final List<BackendRequest?> seen = [];
  BackendResponse Function()? respond;
  Completer<void>? gate;

  @override
  String get baseUrl => 'http://localhost:9000';

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    seen.add(request);
    if (request != null && request.isCancelled) {
      throw BackendRequestAborted('请求已取消');
    }
    if (gate != null) {
      // Model the real transports: the cancellation handle races the wait.
      if (request == null) {
        await gate!.future;
      } else {
        final cancelled = await Future.any<bool>([
          gate!.future.then((_) => false),
          request.whenCancelled.then((_) => true),
        ]);
        if (cancelled) throw BackendRequestAborted('请求已取消');
      }
    }
    if (request != null && request.isCancelled) {
      throw BackendRequestAborted('请求已取消');
    }
    return (respond ?? () => BackendResponse(200, Uint8List(0), ''))();
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('BackendRequest', () {
    test('cancel is idempotent and observable', () async {
      final request = BackendRequest();
      expect(request.isCancelled, isFalse);
      request.cancel();
      request.cancel();
      expect(request.isCancelled, isTrue);
      await request.whenCancelled;
    });

    test('register refuses work once cancelled and reports it', () {
      final request = BackendRequest();
      var cancelled = 0;
      expect(request.register(() => cancelled++), isTrue);
      request.cancel();
      expect(cancelled, 1);
      expect(
        request.register(() => cancelled++),
        isFalse,
        reason: 'a caller that lost the race must learn not to start',
      );
      expect(cancelled, 2);
    });

    test('unregister stops a finished call from being cancelled later', () {
      final request = BackendRequest();
      var cancelled = 0;
      void hook() => cancelled++;
      request.register(hook);
      request.unregister(hook);
      request.cancel();
      expect(cancelled, 0);
    });

    test('request ids are unique across transport instances', () {
      final first = RustBackendTransport();
      final second = RustBackendTransport();
      final ids = {
        RustBackendTransport.nextRequestId(),
        RustBackendTransport.nextRequestId(),
        RustBackendTransport.nextRequestId(),
      };
      expect(ids, hasLength(3));
      // The id source is shared, so a restarted or second transport cannot
      // reissue an id that is still registered in the Rust core.
      expect(first.port, second.port);
    });
  });

  group('ApiClient cancellation', () {
    test('a request cancelled before the call starts never reaches the wire',
        () async {
      var calls = 0;
      final transport = _RecordingTransport()
        ..respond = () {
          calls++;
          return BackendResponse(200, Uint8List(0), '');
        };
      final api = ApiClient(transport: transport);
      final request = BackendRequest()..cancel();

      await expectLater(
        api.withCancellation(request, () => api.detail('1')),
        throwsA(isA<BackendRequestAborted>()),
      );
      expect(calls, 0);
      expect(transport.seen, isEmpty);
    });

    test('cancelling while the call waits aborts it and drops the result',
        () async {
      final gate = Completer<void>();
      final transport = _RecordingTransport()
        ..gate = gate
        ..respond = () =>
            BackendResponse(200, utf8.encode('{"code":200,"data":{}}'), '');
      final api = ApiClient(transport: transport);
      final request = BackendRequest();

      final pending = api.withCancellation(request, () => api.detail('1'));
      // Let the call reach the transport and register its cancellation hook.
      await Future<void>.delayed(Duration.zero);
      expect(transport.seen, hasLength(1));
      expect(transport.seen.single, same(request));

      request.cancel();
      await expectLater(pending, throwsA(isA<BackendRequestAborted>()));

      // A late completion must not resurrect the call.
      gate.complete();
      await Future<void>.delayed(Duration.zero);
    });

    test('a superseding request cancels only the previous one', () async {
      final firstGate = Completer<void>();
      final transport = _RecordingTransport()
        ..gate = firstGate
        ..respond = () =>
            BackendResponse(200, utf8.encode('{"code":200,"data":{}}'), '');
      final api = ApiClient(transport: transport);

      final first = BackendRequest();
      final firstCall = api.withCancellation(first, () => api.detail('1'));
      await Future<void>.delayed(Duration.zero);

      final second = BackendRequest();
      second.cancel();
      first.cancel();

      await expectLater(firstCall, throwsA(isA<BackendRequestAborted>()));
      await expectLater(
        api.withCancellation(second, () => api.detail('2')),
        throwsA(isA<BackendRequestAborted>()),
      );
    });

    test('cancelling after completion changes nothing', () async {
      final transport = _RecordingTransport()
        ..respond = () => BackendResponse(
              200,
              utf8.encode('{"code":200,"data":{"ok":true}}'),
              '',
            );
      final api = ApiClient(transport: transport);
      final request = BackendRequest();

      final page = await api.withCancellation(request, () => api.detail('1'));
      expect(page['code'], 200);
      request.cancel();
      expect(page['data'], {'ok': true});
    });

    test('a plain client keeps working without a cancellation scope', () async {
      final transport = _RecordingTransport()
        ..respond = () => BackendResponse(
              200,
              utf8.encode('{"success":false,"error":"失败"}'),
              '',
            );
      final api = ApiClient(transport: transport);
      await expectLater(
        api.detail('1'),
        throwsA(isA<ApiException>()),
      );
      expect(transport.seen.single, isNull);
    });
  });

  group('HttpBackendTransport cancellation', () {
    /// A server that accepts the connection and never answers, so the only way
    /// out is the client's own abort or deadline.
    Future<HttpServer> stalledServer() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // Accept and hold: nothing is ever written, so only the client can end it.
      server.listen((_) {});
      return server;
    }

    test('cancel before send aborts without issuing a request', () async {
      var issued = 0;
      final client = MockClient((_) async {
        issued++;
        return http.Response('{}', 200);
      });
      final transport = HttpBackendTransport(
        client: client,
        baseUrl: 'http://localhost:9000',
      );
      final request = BackendRequest()..cancel();
      await expectLater(
        transport.send(
          'GET',
          Uri.parse('http://localhost:9000/health'),
          request: request,
        ),
        throwsA(isA<BackendRequestAborted>()),
      );
      expect(issued, 0);
    });

    test('cancel aborts a stalled exchange promptly, not via the deadline',
        () async {
      final server = await stalledServer();
      addTearDown(() => server.close(force: true));

      final transport = HttpBackendTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final request = BackendRequest();
      final stopped = Stopwatch()..start();
      final pending = transport.send(
        'GET',
        Uri.parse('http://127.0.0.1:${server.port}/src/large.mp4'),
        // Far longer than the assertion bound: only the cancel can end this.
        timeout: const Duration(minutes: 5),
        request: request,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      request.cancel();
      await expectLater(
        pending.timeout(const Duration(seconds: 5)),
        throwsA(isA<BackendRequestAborted>()),
      );
      stopped.stop();
      expect(
        stopped.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'cancellation must abort the in-flight exchange, not wait it out',
      );
    });

    test('a deadline still surfaces as TimeoutException', () async {
      final server = await stalledServer();
      addTearDown(() => server.close(force: true));

      final transport = HttpBackendTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final stopped = Stopwatch()..start();
      await expectLater(
        transport.send(
          'GET',
          Uri.parse('http://127.0.0.1:${server.port}/src/large.mp4'),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<TimeoutException>()),
      );
      stopped.stop();
      expect(stopped.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
