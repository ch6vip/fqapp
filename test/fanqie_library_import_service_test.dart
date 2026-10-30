import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/fanqie_library_capture.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/fanqie_library_import_service.dart';

Map<String, dynamic> _source(String resource, dynamic data) => {
  'resource': resource,
  'status': 'received',
  'payload': {'code': 0, 'data': data},
};

/// [books] 本小说，每本都带一个已知 chapterId，预览阶段会去拉目录核对。
FanqieLibraryCapture _capture(int books) {
  final ids = [for (var i = 1; i <= books; i++) '$i'];
  return FanqieLibraryCapture({
    'parts': <String>[],
    'sources': <Map<String, dynamic>>[
      _source('history', {
        'data_list': [
          for (final id in ids)
            {
              'book_id': id,
              'book_type': 0,
              'book_name': 'Book $id',
              'read_timestamp_ms': 1,
            },
        ],
      }),
      _source('progress_list', [
        for (final id in ids)
          {
            'book_id': id,
            'book_type': 0,
            // item_id 必须是纯数字，导入模型才会把它当作章节 ID。
            'item_id': '80$id',
            'read_timestamp_ms': 1,
          },
      ]),
    ],
  });
}

List<List<Chapter>> _chapters(String bookId) => [
  [Chapter(itemId: '80$bookId', title: 'Chapter', volumeName: '')],
];

void main() {
  test('preview resolves directories with bounded concurrency', () async {
    const books = 12;
    var active = 0;
    var peak = 0;
    final started = <String>[];
    final progress = <String>[];

    final preview = await FanqieLibraryImportService().prepare(
      _capture(books),
      BackendRequest(),
      progress.add,
      directoryLoader: (bookId) async {
        active++;
        if (active > peak) peak = active;
        started.add(bookId);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return _chapters(bookId);
      },
    );

    // 并发而不是串行，但最多 4 个目录请求同时在途。
    expect(peak, greaterThan(1));
    expect(peak, lessThanOrEqualTo(4));
    expect(started, hasLength(books));
    expect(preview.matched, books);
    expect(preview.unresolved, 0);
    expect(preview.records, hasLength(books));
    expect(progress, hasLength(books));
  });

  test('preview stops issuing directory requests when cancelled', () async {
    final request = BackendRequest();
    final started = <String>[];
    final fourStarted = Completer<void>();

    final future = FanqieLibraryImportService().prepare(
      _capture(50),
      request,
      (_) {},
      directoryLoader: (bookId) {
        started.add(bookId);
        if (started.length == 4 && !fourStarted.isCompleted) {
          fourStarted.complete();
        }
        return request.whenCancelled.then<List<List<Chapter>>>(
          (_) => throw BackendRequestAborted('请求已取消'),
        );
      },
    );

    await fourStarted.future;
    request.cancel();
    await expectLater(future, throwsA(isA<BackendRequestAborted>()));
    // 取消后不再领取新书：只有已经在途的 4 个请求。
    expect(started, hasLength(4));
  });
}
