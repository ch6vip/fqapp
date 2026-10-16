import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/backend_image_provider.dart';
import 'package:fqapp/services/backend_transport.dart';

/// 1x1 transparent PNG.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
);

class _BytesTransport implements BackendTransport {
  _BytesTransport({required this.status, this.body});

  final int status;
  final Uint8List? body;
  final List<Uri> seen = [];

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    seen.add(url);
    // NOTE: `send`'s own `body` parameter shadows the field; use `this.body`.
    final out = this.body ?? Uint8List(0);
    return BackendResponse(status, out, 'image/png');
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('isBackendResourceUrl only matches /src/ paths', () {
    expect(isBackendResourceUrl('/src/a.webp'), isTrue);
    expect(isBackendResourceUrl('https://cdn.example/a.webp'), isFalse);
    expect(isBackendResourceUrl('/other/a.webp'), isFalse);
    expect(isBackendResourceUrl(''), isFalse);
  });

  testWidgets('loads backend image bytes through the bridge', (tester) async {
    final transport = _BytesTransport(status: 200, body: _pngBytes);
    var errored = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Image(
          image: BackendImageProvider(
            '/src/a.png',
            apiClient: ApiClient(transport: transport),
          ),
          errorBuilder: (_, _, _) {
            errored = true;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(errored, isFalse);
    expect(tester.takeException(), isNull);
    expect(transport.seen.single.path, '/src/a.png');
  });

  testWidgets('surfaces a non-200 backend response as an image error', (
    tester,
  ) async {
    final transport = _BytesTransport(status: 404);
    var errored = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Image(
          image: BackendImageProvider(
            '/src/missing.png',
            apiClient: ApiClient(transport: transport),
          ),
          errorBuilder: (_, _, _) {
            errored = true;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(errored, isTrue);
  });
}
