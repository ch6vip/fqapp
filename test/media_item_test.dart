import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';

void main() {
  test('parses list-shaped chapterListWithVolume', () {
    final payload = {
      'code': 200,
      'data': {
        'data': {
          'chapterListWithVolume': [
            [
              {'itemId': 'c1', 'title': '第一章', 'volume_name': '正文'},
              {'itemId': 'c2', 'title': '第二章'},
            ],
          ],
        },
      },
    };

    final volumes = parseDirectory(payload);
    expect(volumes, hasLength(1));
    expect(volumes.first.map((c) => c.itemId), ['c1', 'c2']);
    expect(volumes.first.first.volumeName, '正文');
  });

  test('parses raw short-drama episodes as chapters', () {
    final payload = {
      'data': {
        'episodes': [
          {'video_id': 'v1', 'title': '第1集'},
          {'item_id': 'v2'},
        ],
      },
    };

    final chapters = parseDirectory(payload).expand((v) => v).toList();
    expect(chapters.map((c) => c.itemId), ['v1', 'v2']);
    expect(chapters.map((c) => c.title), ['第1集', '第2集']);
  });

  test('parses a direct array directory response', () {
    final payload = {
      'code': 200,
      'data': [
        {'item_id': 'c1', 'title': '第一章'},
        {'item_id': 'c2', 'title': '第二章'},
      ],
    };
    final chapters = parseDirectory(payload).expand((v) => v).toList();
    expect(chapters.map((c) => c.itemId), ['c1', 'c2']);
  });

  test('prefers video id over book id for short dramas', () {
    final item = MediaItem.fromRaw({
      'book_id': 'series-book',
      'video_id': 'series-video',
      'cell_name': '短剧',
      'category': '短剧',
    });
    expect(item.kind, 'video');
    expect(item.id, 'series-video');
  });

  test('merges parent metadata into nested video search results', () {
    final tabs = parseSearchTabs({
      'data': {
        'search_tabs': [
          {
            'title': '短剧',
            'data': [
              {
                'series_id': 's1',
                'cell_name': '系列标题',
                'video_data': [
                  {'video_id': 'v1', 'title': '第一集'},
                ],
              },
            ],
          },
        ],
      },
    });
    expect(tabs.single.items.single.id, 's1');
    expect(tabs.single.items.single.seriesId, 's1');
    expect(tabs.single.items.single.kind, 'video');
    expect(tabs.single.items.single.title, '系列标题');
  });

  test('keeps explicit kind when restoring a saved favorite', () {
    final item = MediaItem.fromRaw({
      'id': 'series-1',
      'title': '已收藏短剧',
      'kind': 'video',
      'seriesId': 'series-1',
      'episodeId': 'episode-1',
    });
    expect(item.kind, 'video');
    expect(item.id, 'series-1');
    expect(item.episodeId, 'episode-1');
  });

  test('normalizes localized explicit media kinds', () {
    final item = MediaItem.fromRaw({
      'id': 'series-2',
      'title': '短剧',
      'kind': '短剧',
    });
    expect(item.kind, 'video');
    expect(item.id, 'series-2');
  });

  test('extracts nested recommendation cards', () {
    final items = parseMediaItems({
      'code': 0,
      'data': {
        'tab_item': [
          {
            'cell_data': [
              {
                'cell_data': [
                  {
                    'book_data': [
                      {'book_id': 'b1', 'book_name': '推荐小说'},
                    ],
                  },
                ],
              },
            ],
          },
        ],
      },
    });
    expect(items.single.id, 'b1');
    expect(items.single.title, '推荐小说');
  });
}
