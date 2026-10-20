import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/fanqie_history.dart';

void main() {
  test('one dirty record skips itself instead of blocking the whole page', () {
    final page = FanqieHistoryPage.parse({
      'code': 0,
      'data': {
        'has_more': false,
        'next_offset': 0,
        'data_list': [
          {
            'book_id': '101',
            'book_type': 0,
            'book_name': 'Good',
            'read_timestamp_ms': 100,
          },
          'not-a-record',
          {'book_id': 'bad-id!', 'book_type': 0, 'read_timestamp_ms': 200},
          {'book_id': '103', 'book_type': 0, 'read_timestamp_ms': -5},
          {
            'book_id': '104',
            'book_type': 0,
            'book_name': 12345,
            'thumb_url': ['not', 'a', 'string'],
            'read_timestamp_ms': 300,
          },
          {
            'book_id': '105',
            'book_type': 0,
            'book_name': 'Also good',
            'read_timestamp_ms': 400,
          },
        ],
      },
    });
    expect(page.records.map((r) => r['id']), ['101', '104', '105']);
    expect(page.skipped, 3);
    final blanked = page.records.firstWhere((r) => r['id'] == '104');
    expect(blanked['title'], '');
    expect(blanked['cover'], '');
  });

  test('preview carries the skipped count from the parsed page', () {
    final preview = FanqieHistoryPreview.fromBytes(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'code': 0,
            'data': {
              'has_more': false,
              'next_offset': 0,
              'data_list': [
                {
                  'book_id': '101',
                  'book_type': 0,
                  'read_timestamp_ms': 100,
                },
                {'book_id': 'bad', 'book_type': 0, 'read_timestamp_ms': -1},
              ],
            },
          }),
        ),
      ),
    );
    expect(preview.validated.history, hasLength(1));
    expect(preview.skipped, 1);
    expect(preview.sourceCount, 2);
  });
}
