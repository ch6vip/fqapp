import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_id.dart';

void main() {
  const id = '7677801492920667198';

  test(
    'ID queries keep exact digits and short numeric titles stay keywords',
    () {
      expect(mediaIdFromSearch('  $id  '), id);
      expect(mediaIdFromSearch('00123456789012345678'), '00123456789012345678');
      for (final query in ['1984', '三体', '第$id集', '123456789012345678901']) {
        expect(mediaIdFromSearch(query), isNull);
      }
      expect(mediaIdFromSearch('ID: 1984'), '1984');
      expect(mediaIdFromSearch('id：$id'), id);
      expect(mediaIdFromSearch('id: invalid'), 'invalid');
    },
  );

  test(
    'invalid or empty identities are rejected without integer conversion',
    () {
      for (final value in [
        '',
        '0',
        '0000',
        '-12',
        '1.2',
        '12 34',
        'id:12',
        '12?tab=8',
        '123456789012345678901',
      ]) {
        expect(isValidMediaId(value), isFalse, reason: value);
      }
      expect(isValidMediaId(id), isTrue);
      expect(isValidMediaId('00123456789012345678'), isTrue);
      expect(isValidMediaId('1984'), isTrue);
    },
  );

  for (final sample in [
    (kind: 'book', genre: '0', genreType: '0'),
    (kind: 'video', genre: '203', genreType: '2130'),
    (kind: 'manju', genre: '205', genreType: '2150'),
    (kind: 'manga', genre: '1', genreType: '110'),
    (kind: 'audio', genre: '4', genreType: '1'),
  ]) {
    test('real detail metadata identifies ${sample.kind} by ID', () {
      final metadata = {
        'book_id': id,
        'book_name': '作品名称',
        'genre': sample.genre,
        'genre_type': sample.genreType,
        'author': '作者',
        'thumb_url': 'https://example.com/cover.jpg',
        'serial_count': '63',
      };
      for (final payload in [
        {'code': 0, 'data': metadata},
        {
          'code': 200,
          'data': {
            'book_info': metadata,
            'item_list': ['episode'],
          },
        },
        {
          'data': {
            'data': {
              'book_data': [metadata],
            },
          },
        },
      ]) {
        final item = parseMediaIdResult(payload, id)!;
        expect(item.id, id);
        expect(item.kind, sample.kind);
        expect(item.title, '作品名称');
        expect(item.author, '作者');
        expect(item.ep, '63');
        expect(
          item.seriesId,
          ['video', 'manju'].contains(sample.kind) ? id : null,
        );
        expect(item.episodeId, isNull);
      }
    });
  }

  test(
    'lookup never fabricates a card or picks recommendations and chapters',
    () {
      for (final payload in <Map<String, dynamic>>[
        {},
        {
          'data': {'book_id': id},
        },
        {
          'data': {'book_name': '缺少 ID'},
        },
        {
          'data': {'book_id': 'other', 'book_name': '其他作品'},
        },
        {
          'code': 101104,
          'data': {'book_id': id, 'book_name': '无效数据'},
        },
        {
          'data': {'code': 101104, 'book_id': id, 'book_name': '无效数据'},
        },
        {
          'data': {
            'recommendations': [
              {'book_id': id, 'book_name': '推荐作品'},
            ],
          },
        },
        {
          'data': {
            'item_data_list': [
              {'item_id': id, 'title': '章节标题'},
            ],
          },
        },
      ]) {
        expect(parseMediaIdResult(payload, id), isNull, reason: '$payload');
      }
    },
  );

  test('metadata titles cannot change a novel into a manju', () {
    final item = parseMediaIdResult({
      'data': {'book_id': id, 'book_name': '漫剧改编原著', 'genre': '0'},
    }, id)!;
    expect(item.kind, 'book');
  });
}
