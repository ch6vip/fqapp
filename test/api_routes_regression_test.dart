import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Guards against the client drifting back onto routes the backend removed.
///
/// The built-in Web UI and its `/api/*` bridge were deleted; every business
/// call must go through `/api/v1/*`. When `api_client.dart` still pointed at
/// `/api/directory` and `/api/content`, the whole suite stayed green because
/// the tests asserted those same dead paths — implementation and expectation
/// were wrong together. This test records the paths the client actually emits,
/// so a reintroduced bridge path fails here instead of in the field.
void main() {
  const base = 'http://localhost:9000';

  test('every emitted business path lives under /api/v1', () async {
    final paths = <String>[];
    final transport = MockClient((request) async {
      paths.add(request.url.path);
      return http.Response.bytes(utf8.encode(jsonEncode({'code': 0, 'data': {}})), 200);
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: base);

    final calls = <Future<void> Function()>[
      () => api.search('q'),
      () => api.searchTabs('q'),
      () => api.searchTabs('q', tabType: 8, offset: 0),
      () => api.detail('book'),
      () => api.directory('book'),
      () => api.directoryChapters('book'),
      () => api.content('chapter'),
      () => api.content('chapter', tab: '漫画'),
      () => api.content('chapter', tab: '短剧', mode: 'stream'),
      () => api.contentText('chapter'),
      () => api.bookDetail('book'),
      () => api.homepageRecommend(tabType: 8, offset: 0),
    ];
    for (final call in calls) {
      try {
        await call();
      } catch (_) {
        // Parsing may reject the empty payload; the recorded path is the point.
      }
    }

    expect(paths, isNotEmpty);
    for (final path in paths) {
      expect(
        path,
        startsWith('/api/v1/'),
        reason: 'removed Web bridge path came back: $path',
      );
    }
  });

  test('the composite content routes map tab to its own endpoint', () async {
    final paths = <String>[];
    final transport = MockClient((request) async {
      paths.add(request.url.path);
      return http.Response.bytes(
        utf8.encode(jsonEncode({'code': 0, 'data': {}})),
        200,
      );
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: base);

    for (final tab in ['小说', '漫画', '短剧', '漫剧']) {
      try {
        await api.content('item1', tab: tab);
      } catch (_) {
        // Envelope parsing is irrelevant here.
      }
    }

    expect(paths, [
      '/api/v1/chapters/item1',
      '/api/v1/manga/item1',
      '/api/v1/videos/item1',
      '/api/v1/videos/item1',
    ]);
  });

  test('directory answers the upstream shape without the bridge transform', () {
    // Shape returned by /api/v1/books/<id>/directory: the chapter list sits
    // beside `data.data`, not pre-flattened inside it.
    const payload = {
      'code': 0,
      'data': {
        'data': {'some_upstream_field': 1},
        'item_data_list': [
          {'item_id': 'c1', 'title': '第1章', 'volume_name': '正文'},
          {'item_id': 'c2', 'title': '第2章', 'volume_name': '正文'},
        ],
      },
    };

    final chapters = parseDirectory(payload).expand((v) => v).toList();
    expect(chapters.map((c) => c.itemId), ['c1', 'c2']);
    expect(chapters.map((c) => c.title), ['第1章', '第2章']);
    expect(chapters.every((c) => c.volumeName == '正文'), isTrue);
  });
}
