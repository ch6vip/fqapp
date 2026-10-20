import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/fanqie_library_import.dart';
import 'package:fqapp/models/media_item.dart';

Map<String, dynamic> source(String resource, dynamic data) => {
  'resource': resource,
  'status': 'received',
  'payload': {'code': 0, 'data': data},
};

void main() {
  test(
    'only explicit novels enter the import; metadata alone adds nothing',
    () {
      final parser = FanqieLibraryImport();
      parser.addSource(
        source('history', {
          'data_list': [
            {
              'book_id': '101',
              'book_type': 0,
              'book_name': 'Novel',
              'read_timestamp_ms': 100,
            },
            {'book_id': '102', 'book_type': 1},
            {'book_id': '103', 'book_type': 6},
            {'book_id': '104', 'book_type': 0, 'is_delete': true},
          ],
        }),
      );
      parser.addSource(
        source('book_detail', {'book_id': '999', 'book_name': 'Unrelated'}),
      );
      expect(parser.records.map((r) => r['id']), ['101']);
      expect(parser.skipped, 3);
    },
  );

  test('shelf and history share one identity, enriched by public metadata', () {
    final parser = FanqieLibraryImport();
    parser.addSource(
      source('shelf_list', {
        'book_shelf_info_all': [
          {'book_id': '101', 'book_type': 0},
          {'book_id': '102', 'book_type': 0},
        ],
      }),
    );
    parser.addSource(
      source('history', {
        'data_list': [
          {'book_id_str': '101', 'book_type': 0, 'read_timestamp_ms': 100},
        ],
      }),
    );
    parser.addSource(
      source('book_detail', {
        'book_id': '101',
        'book_name': 'Novel',
        'author': 'Author',
        'thumb_url': 'https://example.com/cover.jpg',
      }),
    );
    expect(parser.records, hasLength(2));
    final record = parser.records.firstWhere((r) => r['id'] == '101');
    expect(record['title'], 'Novel');
    expect(record['cover'], 'https://example.com/cover.jpg');
    expect(record['time'], 100);
    expect(record['fanqieImported'], true);
    expect(record.containsKey('episode'), false);
  });

  test(
    'latest official chapter wins without interpreting paragraph sentinels',
    () {
      final parser = FanqieLibraryImport();
      parser.addSource(
        source('progress_list', [
          {
            'book_id': '101',
            'book_type': 0,
            'item_id': '202',
            'read_timestamp_ms': 200,
            'paragraph_id': 10000,
            'paragraph_offset': 7,
          },
        ]),
      );
      parser.addSource(
        source('progress_batch', [
          {
            'book_id': '101',
            'book_type': 0,
            'item_id': '201',
            'read_timestamp_ms': 100,
          },
        ]),
      );
      final record = parser.records.single;
      expect(record['chapterId'], '202');
      expect(record['officialAnchor'], {
        'paragraph_id': 10000,
        'paragraph_offset': 7,
      });
      expect(record.containsKey('textOffset'), false);
      expect(record.containsKey('position'), false);
    },
  );

  test('directory identity decides the resume index, not upstream order', () {
    final record = <String, dynamic>{
      'chapterId': '202',
      'officialAnchor': {'order': 8, 'real_chapter_order': 2},
    };
    final chapters = [
      Chapter(itemId: '201', title: 'First', volumeName: ''),
      Chapter(itemId: '202', title: 'Second', volumeName: ''),
    ];
    expect(resolveFanqieChapter(record, chapters), true);
    expect(record['episode'], 1);
    expect(record['progress'], .5);
    final unavailable = <String, dynamic>{'chapterId': '999'};
    expect(resolveFanqieChapter(unavailable, chapters), false);
    expect(unavailable, {'chapterId': '999'});
  });

  test(
    'nested recommendations inside a book record are not shelf entries',
    () {
      final parser = FanqieLibraryImport();
      parser.addSource(
        source('shelf_list', {
          'book_shelf_info_all': [
            {
              'book_id': '101',
              'book_type': 0,
              'book_name': 'Shelved',
              'recommend_books': [
                {'book_id': '201', 'book_type': 0, 'book_name': 'Rec 1'},
                {'book_id': '202', 'book_type': 0, 'book_name': 'Rec 2'},
              ],
            },
          ],
        }),
      );
      expect(parser.records.map((r) => r['id']), ['101']);
    },
  );

  test('books nested in folders still import through non-book containers', () {
    final parser = FanqieLibraryImport();
    parser.addSource(
      source('folder_detail', {
        'folder_name': 'My folder',
        'book_list': [
          {'book_id': '101', 'book_type': 0},
          {'book_id': '102', 'book_type': 0},
        ],
        'sub_folders': [
          {
            'folder_name': 'Nested',
            'book_list': [
              {'book_id': '103', 'book_type': 0},
            ],
          },
        ],
      }),
    );
    expect(parser.records.map((r) => r['id']), ['101', '102', '103']);
  });

  test('failed responses cannot import the payload they carry', () {
    final parser = FanqieLibraryImport();
    parser.addSource({
      ...source('progress_list', [
        {'book_id': '101', 'book_type': 0, 'item_id': '201'},
      ]),
      'status': 'failed',
    });
    expect(parser.records, isEmpty);
    expect(parser.failed, 1);
  });
}
