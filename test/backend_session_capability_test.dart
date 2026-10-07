import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/models/backend_resource_url.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/backend_transport.dart';

/// Stands in for the FFI transport so resource-URL composition can be checked
/// without a live core.
class _CapabilityTransport implements BackendTransport {
  _CapabilityTransport({required this.baseUrl, required this.capability});

  @override
  final String baseUrl;

  @override
  final String capability;

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    throw UnimplementedError('not used by these tests');
  }

  @override
  Future<void> close() async {}
}

void main() {
  // The loopback adapter only answers a request carrying its per-launch
  // capability. Resource URLs are the one surface where the capability has to
  // travel inside the path, so these guard the composition and the resolution
  // that keeps it from being dropped.
  group('resolveBackendResource', () {
    const base = 'http://127.0.0.1:8080/_session/abc/';

    test('keeps the capability when re-anchoring a root-relative path', () {
      expect(
        resolveBackendResource(base, '/src/chapter.webp'),
        'http://127.0.0.1:8080/_session/abc/src/chapter.webp',
      );
    });

    test('keeps the capability for a relative path', () {
      expect(
        resolveBackendResource(base, 'src/chapter.webp'),
        'http://127.0.0.1:8080/_session/abc/src/chapter.webp',
      );
    });

    test('preserves a query on a backend-relative path', () {
      expect(
        resolveBackendResource(base, '/src/x.mp4?token=abc123'),
        'http://127.0.0.1:8080/_session/abc/src/x.mp4?token=abc123',
      );
    });

    test('leaves a signed CDN URL untouched', () {
      const cdn = 'https://cdn.example/audio.m4a?sign=a%2fb+xyz';
      expect(resolveBackendResource(base, cdn), cdn);
    });

    test('still resolves against a capability-free base', () {
      expect(
        resolveBackendResource('http://127.0.0.1:8080/', '/src/x.webp'),
        'http://127.0.0.1:8080/src/x.webp',
      );
    });

    test('a protocol-relative value keeps its own host', () {
      expect(
        resolveBackendResource(base, '//cdn.example/x.webp'),
        'http://cdn.example/x.webp',
      );
    });
  });

  group('backendResourceBase', () {
    test('appends the capability as a path segment', () {
      expect(
        backendResourceBase('http://127.0.0.1:8080', 'abc'),
        'http://127.0.0.1:8080/_session/abc/',
      );
    });

    test('stays capability-free when none is known', () {
      expect(
        backendResourceBase('http://127.0.0.1:8080', ''),
        'http://127.0.0.1:8080/',
      );
    });
  });

  group('resource URLs', () {
    test('absoluteUrl carries the capability', () {
      final api = ApiClient(
        transport: _CapabilityTransport(
          baseUrl: 'http://127.0.0.1:8080',
          capability: 'abc',
        ),
      );
      expect(
        api.absoluteUrl('/src/x.webp'),
        'http://127.0.0.1:8080/_session/abc/src/x.webp',
      );
      expect(
        api.absoluteUrl('https://cdn.example/x.webp'),
        'https://cdn.example/x.webp',
      );
    });

    test('the HTTP transport presents the capability as a bearer token',
        () async {
      String? seen;
      final transport = HttpBackendTransport(
        client: MockClient((request) async {
          seen = request.headers['authorization'];
          return http.Response('{}', 200);
        }),
        baseUrl: 'http://127.0.0.1:8080',
        capability: 'abc',
      );
      await transport.send('GET', Uri.parse('http://127.0.0.1:8080/health'));
      expect(seen, 'Bearer abc');
    });

    test('the HTTP transport sends no token without a capability', () async {
      String? seen;
      final transport = HttpBackendTransport(
        client: MockClient((request) async {
          seen = request.headers['authorization'];
          return http.Response('{}', 200);
        }),
        baseUrl: 'http://127.0.0.1:8080',
      );
      await transport.send('GET', Uri.parse('http://127.0.0.1:8080/health'));
      expect(seen, isNull);
    });
  });
}
